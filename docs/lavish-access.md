# Reachable review boards

Lavish review boards are how firstmate hands the captain a decision surface.
A bare `lavish-axi` binds loopback and writes `http://127.0.0.1:<port>/...` into the link it hands over, which opens nothing on his PC or phone.
The failure is silent: the board renders correctly on the machine that made it, so nothing signals that the link is dead everywhere else.

`bin/fm-lavish.sh` is the entry point that fixes it, `bin/fm-service-port.sh` is the general port allocator underneath it, and `bin/fm-lavish-pretool-check.sh` is the guard that stops an agent reaching for the old command out of habit.
Each script's header owns its exact flags and mechanics; this document owns the contract between them, the reasoning, and the validation record.

## Read this first: one acceptance criterion is not proven

The second acceptance criterion - an HTTP 200 for a board fetched from a *different* device on the tailnet - is **not proven**.
It could not be proven from the machine this was built on: the other Linux nodes reject `tailscale ssh` with no known host key, and the captain's PC and phone cannot be driven by an agent.

What is proven is everything on this side of the wire: the server binds only the tailnet address and loopback is not served, the emitted hostname resolves to that address, a request carrying the tailnet name is accepted by the Host allowlist and returns 200, and the tailnet peer path to the captain's PC answers.
So the mechanism is demonstrated up to the last hop, and the last hop is the part nobody here can perform.

One fetch of a wrapper-emitted link, from the captain's own PC or phone, closes it.
The phone is the case worth doing specifically, for the reason recorded under "Open gap: the off-device request" at the end of this document, which also carries the full attempt log.

## Why this could not be a documented environment variable

`~/.bashrc` returns immediately for non-interactive shells, and an agent tool shell loads its own snapshot instead, so an operator's profile export never reaches an agent's invocation.
That route had already been tried here and had already failed once: the problem was written onto a review board, and the link to that same board went out on loopback.
The fix therefore has to be a firstmate-owned mechanism that is hard to bypass by habit, not a note somebody has to remember.

## What the entry point sets

| Variable | Value | Why |
| --- | --- | --- |
| `LAVISH_AXI_HOST` | this vessel's tailnet IPv4 address, or loopback where that address cannot be bound | reachable off this machine, and never a wildcard, because an all-interfaces bind is broader than was approved |
| `LAVISH_AXI_PORT` | a port proved free by `bin/fm-service-port.sh` | vessels sharing one machine do not collide |
| `LAVISH_AXI_LINK_HOST` | the tailnet DNS name, but only once it has been confirmed to resolve to this node's tailnet address; otherwise that address, and loopback only when no reach was established at all | the hostname the captain actually receives is checked before he receives it, and it names where the board answers rather than where it is bound |
| `LAVISH_AXI_ALLOWED_HOSTS` | this vessel's DNS name, short node name, address, and this home's claim token; never `*` | a closed Host allowlist rather than an open one |
| `LAVISH_AXI_STATE_DIR` | `FM_HOME/state/lavish` | a secondmate home shares its UNIX account with its parent, so without this they share one server and one session store |

Every value is resolved at runtime from `tailscale status --json`.
Nothing vessel-specific is compiled in, which is what makes this work on every vessel including secondmate homes rather than only on the one it was built on.

## The three failures this design is built around

Each was measured on `crew-hlr` on 2026-07-30, not inferred.

### A fixed default port is contended across UNIX accounts

This host carries three accounts (`coditan`, `crew`, `tugboat`).
`lavish-axi`'s compiled-in default is 4387, and on this host 4387 was already held by a different account by something that is not even an HTTP server.
No vessel may assume a fixed port, so `bin/fm-service-port.sh` derives a deterministic preferred seat and probes forward from it.

### A same-version neighbour is silently adopted, not refused

`ensureServer()` decides whether to reuse an existing server purely from the `/health` body, and `shouldRestartServer` returns false when the version matches.
Every `lavish-axi` of the same version returns a byte-identical body, so a vessel configured onto a port another UNIX account already serves does not collide loudly - it adopts that account's server process and emits a URL pointing at it.

This is why `bin/fm-lavish.sh` writes a per-home **claim token** into the Host allowlist.
A request carrying `Host: <token>` is accepted only by a server that was started with that token, so one probe answers "is the server on my port MY server", which no shared health body can answer.
The token adds no exposure: anything that can already reach the port can already reach it under the address, and the token only makes one specific Host header identify one specific home's server.

### Setting the environment at call time does not fix an already-running server

The session URL is built inside the server process from the environment it was born with, and the server is spawned detached by whichever invocation first started it.
So exporting a corrected `LAVISH_AXI_LINK_HOST` on a later invocation changes nothing while a healthy server is still running on that port.
`bin/fm-lavish.sh` records the configuration it launched a server with, compares it on the next run, and restarts its own server on a mismatch - which is safe only because the claim token has already proved the process belongs to this home.

That comparison is made against the configuration the ALLOCATION resolved, never against the `--check` pre-read.
The pre-read cannot know whether a proxy will publish, because no port exists yet, so on a vessel that degrades to loopback every time it never agrees with the record it wrote a moment earlier.
Comparing against it would find a mismatch on every single open, poll, and end, and would restart a perfectly healthy board - dropping the reviewer's connected browser - to re-allocate the identical port and the identical link host.

Stopping reaches into a running process the same way, so it carries the same proof, and an explicitly named port is no exception.
`lavish-axi stop` shuts down whatever answers `/health` with a lavish-axi body on the address it is handed, without authentication and without regard for the owning UNIX account, and every co-hosted vessel binds that same address.
So `bin/fm-lavish.sh stop --port <n>` runs the claim-token probe against `<n>` before it reaches `lavish-axi` at all: a port that answers but is not this home's is refused by name and left running, and a port that answers nothing is reported as nothing to stop.

A port outside the currently resolved window counts as the same kind of staleness: an operator who narrows `FM_SERVICE_PORT_RANGE` to move this service off a conflict would otherwise keep the old port forever, because it is still legitimately ours.
The two cases are handled differently on purpose.
When the same port is still wanted, the port is claimed back as this home's own and the old server is then stopped, so the seat is reclaimed immediately and the publication that names it is left standing across the restart.
When a different port is wanted, the working board keeps serving until a replacement port has actually been secured, so a failed move cannot turn into a lost board - and a successful move says plainly that links already handed over on the old port stop working.

## The port allocator

`bin/fm-service-port.sh` is general: Lavish is its first consumer, not its subject, because any vessel-local service has this problem.

Two rules it exists to enforce:

- **A successful bind is the only proof a port is free.**
  No registry file can stop another UNIX account's process from taking a port, and a stale entry claiming otherwise would be one more instrument reporting success while being wrong.
  The allocator probes with `bin/fm-service-port-probe.mjs`, which performs the same `net.Server.listen()` a Node service will perform, and treats `EADDRINUSE` as authoritative.
  A specific-address bind also fails against a holder that bound the wildcard, so probing `<tailnet-addr>:<port>` detects `0.0.0.0` squatters from other accounts too.
- **The record is a published fact, not a reservation.**
  `FM_HOME/state/service-port.<service>` is written after the fact and says so in its own first lines.
  Nothing reads it to decide availability.

The deterministic seat is `4400 + cksum("<service>\n<vessel>\n<realpath FM_HOME>") % 100`, probing forward with wraparound over the whole window.
`FM_HOME`'s realpath is in the key rather than the vessel id alone, because a secondmate home shares both the id and the UNIX account with its parent - exactly the case that must not collide.
The window sits above 4387 so a stray bare invocation never lands on an allocated seat, and far below this host's ephemeral range of 32768-60999.

A bound port that is released before the consumer's own `listen()` is a genuine race, and it is handled by the consumer retrying rather than by pretending the probe reserved anything.

## Honest degradation

The rule is that no URL is emitted implying reach the vessel has not established.

- **No usable tailnet** - `reachability=loopback` with a concrete reason, and the wrapper prints `no tailnet on this host (<reason>) - this board opens only on this machine.` alongside Lavish's own output.
  The board still opens locally and is never presented as reachable.
- **The tailnet name does not resolve to the bound address** - the link falls back to the address and the reason says so, rather than writing an unchecked name into the captain's link.
- **The tailnet name could not be checked at all**, because `node` or the probe is unavailable - the link falls back to the address and the reason says *that*, since reporting a resolution failure that was never attempted is a concrete diagnosis that happens to be untrue.
- **Nothing established either way** - `reachability=untested`, on a vessel whose first port-claiming run neither published a route nor found one, and the wrapper prints `nothing has established whether this vessel is reachable off this machine (<reason>) - this board certainly opens here, and the next open settles the rest.`
  That is deliberately not either loopback sentence: an untested vessel has not been shown unreachable.
- **The link host does not answer after the board opens** - the wrapper names the address form that does work.
- **Every candidate port is taken** - `bin/fm-service-port.sh` exits non-zero with one plain sentence and no board is opened.
  There is deliberately no silent loopback downgrade here, because that would reproduce the original bug somewhere new.
- **The address cannot be bound at all** - the vessel says so and is served anyway, over a published proxy; see "A tailnet address that cannot be bound" below.
  When even that is unavailable the allocator degrades to `reachability=loopback` carrying the same diagnosis, because a proxy that could not be published is not reach.
  The wrapper says `this vessel is not reachable off this machine (<reason>) - this board opens only on this machine.` on that degrade, not the no-tailnet sentence above, because this node does have a tailnet address and sending the reader hunting a missing one is the misdirection the reason lines exist to avoid.
  It is never reported as a port collision, because that is a network-interface problem and reporting it as contention would send the reader hunting the wrong thing.
  Only address-scoped errnos (`EADDRNOTAVAIL`, `EAFNOSUPPORT`, `EINVAL`) count as this, and they are the only ones that end the walk early, since no port on that address could have worked.
  A port-scoped refusal such as `EACCES` on a privileged port is neither a collision nor an unusable address: the walk continues past it, and only if nothing in the window binds does the allocator report that some candidates were held and others refused.

### A tailnet address that cannot be bound

A tailscale node can hold an ADDRESS without the machine having an INTERFACE for it.
In userspace networking mode - no `/dev/net/tun`, no `NET_ADMIN` in the bounding set - `tailscaled` runs its own network stack, so the node is genuinely on the tailnet while no local interface carries its address.
Every `bind()` on that address fails `EADDRNOTAVAIL`, for every port, so no port window can rescue it.

That is neither of the two cases the allocator originally had a name for.
It is not `tailnet`, because nothing on this machine can listen on the address.
It is not `loopback`, because the vessel really is reachable from the captain's devices.
So it is `reachability=tailnet-proxied`: the port is bound on loopback and reached over the tailnet address through a `tailscale serve` route, whose listener lives inside `tailscaled`'s userspace stack rather than on a host interface.

Three facts this rests on, each measured rather than reasoned about, with the measurements in "The userspace-mode vessel" below.

- The published port and the loopback port are deliberately the same number.
  Lavish writes its own bound port into every link it emits and has no environment variable that separates the two, so a proxy on a different port would emit a link answering nothing.
  The two listeners never collide despite the shared number, because one is on the tailnet address inside the userspace stack and the other is on `127.0.0.1`.
- A request arriving through the proxy carries `Host: <tailnet-dns-name>:<port>`, and Lavish compares its allowlist on hostname alone.
  So the names the wrapper already allows are the names the proxy needs, and no wildcard is introduced.
- The proxy is withdrawn when the board is stopped.
  Left behind, this vessel's own tailnet name answers `502` on that port, which reads as a broken board rather than a closed one.

One design rule sits on top of those three, and it is reasoned rather than measured.
The route is published only for a run that will LEAVE a board serving, which the wrapper states to the allocator with `--serving`.
`open`, `poll`, and `server` do, unless the argv carries a help flag, which answers usage and reaches no handler; `end` closes the last session and lets the server stop itself, so publishing for either would manufacture a route to nothing that outlives the process and the machine's next reboot.
A route the wrapper did publish is withdrawn again when no session link came back, because the argv shape is a prediction and the emitted link is the observation.

That choice is carried by `route=`, never by `reachability=`.
`reachability` is a fact about the HOST, so a vessel that can be reached by proxy stays `tailnet-proxied` on a run that published nothing, and `route=none` is what says this run made no route.
That holds because such a run CARRIES FORWARD what a previous allocation established rather than asserting it afresh, and with nothing to carry it says `untested` rather than inventing either answer.
Reading it the other way would tell the captain his vessel is unreachable because he closed a board, overwrite the published record every consumer of the fleet registry reads, and silence the `LAVISH_ACCESS` notice that is supposed to catch a stale loopback link on exactly that vessel.
A port some earlier run already published reports `route=published` without `--serving`, because reading a route is not making one.
Each verdict also travels with `reachability_evidence`, naming how it was established, and `bin/fm-service-port.sh`'s header owns the full vocabulary of all three fields, while `bin/fm-reachability-lib.sh` owns the rule that a verdict may never claim more reach than something has established.

`bin/fm-tailnet-serve-lib.sh` is the one owner of publishing and withdrawing.
Serve configuration belongs to the tailscale node, which every UNIX account on this machine shares, so a port is only ever withdrawn where its ownership has already been proved by the claim token, or where nothing is serving on it at all.

### An explicit stop is not the only way a board ends

`lavish-axi` stops itself after `LAVISH_AXI_IDLE_TIMEOUT_MS` with no connections, and immediately when the last session ends with nothing connected.
Neither path runs a line of `bin/fm-lavish.sh`, so neither withdraws anything, and a crash or a reboot leaves the same residue.
What survives is worse than a `502`: the entry outlives the board and then republishes whatever binds that loopback port next - a co-hosted vessel's board, or any local-only tool that lands in the 4400-4499 window - to the whole tailnet under this node's name, which is wider than the account that published it ever approved.

So every run that could open or stop a board first reconciles the publication, before it decides anything else.

**The scope of that reconcile is deliberately narrow, and it must stay narrow.**
It touches only THIS home's own port, proved through this home's own `state/service-port.<service>` record, and only while nothing at all answers behind it.
It is not a sweep of `tailscale serve status`, and it must never be "improved" into one.
Serve configuration is node-wide across every UNIX account on this machine, so reaching an entry this vessel has not proved is its own is the same harm as withdrawing a neighbour's published port - at a larger blast radius, because a sweep does it to every account at once.
Measured on `coditan-vessel` while this rule was written: a second, unrelated residue was live on 8443 proxying to `127.0.0.1:4391`, and its target still answered `200`.
It is out of scope on both counts - not this home's port, and not dead - and it was left untouched.

When no proxy can be published, the link falls back to loopback and the wrapper says the board opens only on this machine.
The promise this whole mechanism makes was never "bind the tailnet address"; it was "never hand the captain a link that opens nowhere", and a tailnet link on a vessel with no proxy would break exactly that promise.
The wrapper therefore re-reads the resolution from the allocation rather than from its own `--check` pre-read: whether a proxy can be published is only answerable once a port exists, so the pre-read cannot know it, and a wrapper that trusted the pre-read emitted a tailnet link on a vessel that had none.

The diagnosis is not removed by any of this.
A vessel in this state still says, on every open, that its address cannot be bound and that this is what userspace mode looks like; what changed is that the board also works.
The durable alternative - giving the container `/dev/net/tun` and `NET_ADMIN` so tailscale runs in kernel mode - is a change to the vessel definition and is not this mechanism's to make.

A readiness probe must target the address that was bound.
Probing loopback while a service binds only a tailnet address reports a healthy server as failed to start; that happened during this investigation and cost real time.
`bin/fm-service-port-probe.mjs http` exists so callers cannot get this wrong by accident.

### The wrapper observes rather than predicts

Sentences about a **link** are held back until the wrapper has seen a link.
It decides that from a session URL in what the run printed, not from the shape of the arguments it was given.

The reason is that argument shapes cannot answer the question.
`lavish-axi` dispatches `open` for `--help <board>.html` and for `open --help`, and then its CLI layer returns the command's help text without ever calling the handler, so an invocation that dispatches `open` can still open nothing.
Predicting that from argv means keeping a copy of somebody else's argument handling and getting it wrong on the next shape, which is what happened twice here before this rule replaced it.
Observation has no such failure mode: no session URL means no link exists, and silence is the only honest thing to say about a link that does not exist.

Sentences about the **host** are a different kind of fact and must not be held back with them.
Whether this vessel has a usable tailnet is settled before anything runs, and no run changes it, so `no tailnet on this host ... this board opens only on this machine.` goes out on every invocation that could open a board.
Telling somebody their boards are local-only when they only asked for help is harmless noise; staying quiet about it on a genuinely loopback-only host is the exact silent failure this mechanism exists to end, so the two are deliberately not gated together.

That leaves one dependency on somebody else's output shape, and it is pinned rather than trusted.
`tests/fm-lavish-access.test.sh` opens a board with the *installed* `lavish-axi` and asserts its output still carries the session URL the wrapper looks for, so a future release that changes that shape fails a test here instead of quietly disabling the link check.
The test skips visibly when `lavish-axi` is not installed, because a check that passes without checking anything is the same failure in a smaller package.

Two things still have to be decided before the run, and are therefore still decided from the arguments.
The port claim comes first because a port has to exist before the command can run at all, so `bin/fm-lavish.sh open --help <board>.html` does take a port from the window, does rewrite `state/service-port.lavish`, and can relocate this vessel's own server on the way.
It no longer rewrites `state/lavish/fm-owner` and no longer restarts a running board, because both describe a server this shape never launches.
That is the wrapper's ordinary open bookkeeping against its own home rather than a false statement to the captain, and closing it would mean running the command before knowing what port to run it on.
The other is a command that replaces this process with `lavish-axi` (`poll`, `end`, `server`): nothing after an `exec` can observe anything, which is one more reason the host's own reachability is stated before the run rather than after it.

## Third-party publishing is refused by default

`lavish-axi share` publishes a board to third-party hosting.
Review boards carry vessel names, security findings, and captain decisions, so `bin/fm-lavish.sh share` refuses unless `--fm-allow-share` or `FM_LAVISH_ALLOW_SHARE=1` makes the intent explicit.
This does not remove the capability, it requires intent, and the refusal names the override rather than being a dead end.

Lavish's own browser chrome also offers a publish action in its overflow menu.
That path is the reviewer's own choice in their own browser and is outside this wrapper's reach; the refusal covers the command line, which is where an agent would reach for it.

## What this does not do

A board remains an unauthenticated server that anything on the tailnet can read.
That is the fleet's existing trust boundary, not a new exposure, and this design does not widen it - the bind is one specific address, the Host allowlist is closed, and nothing is published outside the tailnet.
It does not close it either, and no part of this should be read as adding authentication.

## The guard

`bin/fm-lavish-pretool-check.sh` denies a bare `lavish-axi` in command position and names the wrapper in the reason.
`bin/fm-lavish-command-policy.mjs` owns the decision and imports the shell classifier from `bin/fm-arm-command-policy.mjs`, so it never duplicates shell lexing and never evaluates a byte of the submitted command.

Its scope deliberately differs from the cd-guard (`docs/cd-guard.md`), which is inert outside a plain primary checkout.
This guard fires wherever `bin/fm-lavish.sh` exists, **including a linked task worktree**, because boards get opened from crew worktrees too and a guard that is inert exactly where the mistake happens is not a guard.

Its structural limit, stated rather than implied: the hook is registered by firstmate's own harness configuration, so it reaches firstmate checkouts and not a worktree of some other project.
`bin/fm-brief.sh` covers that gap by naming the wrapper in every generated brief's rules.

`command -v lavish-axi` and `type lavish-axi` are allowed: they ask whether the tool exists, never start a server, and `bin/fm-bootstrap.sh` does exactly this, so denying them would break tool detection to prevent nothing.
The same reasoning allows the subcommands that neither start a server nor emit a link - `setup`, `playbook`, `design`, and `export` - because `bin/fm-bootstrap.sh` and `bin/fm-axi-suite.sh` print `... && PATH=<bin>:$PATH lavish-axi setup hooks` as the install command the captain is told to run, and a guard that denies its own repo's instructions prevents nothing while costing trust in every other denial.
Those four are safe to allow for one specific reason: `lavish-axi` rewrites an argv into `open` only when the first word is not one of its own subcommands, so an HTML path after `export` cannot turn it into a board.
Version and help flags are NOT allowed, even though they serve nothing on their own, because that rewrite makes `lavish-axi --version board.html` an `open`.
Separating those would mean keeping a second copy of `lavish-axi`'s argv normalisation in this guard, which would drift; a wrong allow here is silent, while a wrong deny is loud and answered by running the wrapper.
Because that deny sends `lavish-axi --version` through `bin/fm-lavish.sh`, the wrapper does mirror the one fact the guard refuses to: a flag-led argv opens a board only when some argument is an html path.
The asymmetry is the point rather than an inconsistency - the guard fails safe by denying and never runs anything, while the wrapper has to run the command, and treating `--version` as an open would claim a port, rewrite this home's records, and then report on a board that was never opened.
`stop` is deliberately not on that list either: shutting a server down is the ownership-sensitive action described above, and the wrapper is the path that proves the port first.

## The startup regression check

`bin/fm-bootstrap.sh`'s `lavish_access_check` prints `LAVISH_ACCESS:` when this vessel has a tailnet but open board links still point at loopback.
It reads the wrapper's own session store and the default `~/.lavish-axi/state.json`, which is where a bare invocation writes.
It is detect-only, ordered so the cheap file reads run before the address resolver, and silent on a host with no tailnet.
`bootstrap-diagnostics` owns the response.

This check is the reason the fix cannot regress unnoticed, which matters because it already did regress once while the fix sat queued.

## Compatibility review

- **Harnesses** (claude, codex, opencode, pi, grok) - the wrapper and the allocator are ordinary scripts and are harness-neutral.
  The guard is not, and is registered on all five surfaces the way the cd-guard is: `.claude/settings.json` for Claude, `.codex/hooks.json` for Codex with the same self-registration check the other Codex hooks use, `.grok/hooks/fm-primary-lavish-check.json` for Grok, `.opencode/plugins/fm-primary-lavish-check.js` for OpenCode, and a `runChecker` call in `.pi/extensions/fm-primary-turnend-guard.ts`'s `tool_call` handler for Pi.
  The last two consume the `--command` CLI form plus exit 2 and stderr, which the transport already emits.
  Leaving OpenCode and Pi unregistered would have left the guard inert on two of the five harnesses this fleet spawns agents on, which is the same "inert exactly where the mistake happens" failure the scope decision above exists to avoid.
  What each registration actually reaches differs, and the difference is worth stating rather than rounding up.
  OpenCode reaches everything: a crewmate runs inside its worktree and OpenCode discovers `.opencode/plugins/` from the project root, so the plugin loads there as well as in the primary.
  Pi reaches the primary session and a Pi secondmate home, which are the sessions launched with `-e .pi/extensions/fm-primary-turnend-guard.ts`, and it does not reach a Pi crewmate or scout: `bin/fm-spawn.sh` launches those with a generated per-task extension that carries a `turn_end` handler and no `tool_call` hook at all.
  That is the same structural limit the cd-guard already has on Pi crews and is not something this change introduces; closing it means changing what `bin/fm-spawn.sh` generates for every Pi crew launch, which is its own task rather than a rider on this one.
  A Pi crewmate is covered by the brief rule instead, which is the same fallback `bin/fm-brief.sh` provides for worktrees of other projects.
- **Runtime backends** (tmux, herdr, zellij, orca, cmux) - not applicable, confirmed by inspecting `bin/fm-backend.sh`'s surface rather than assumed.
  No backend touches service ports or the AXI prefix, and the allocator runs inside an already-spawned worker's shell.
- **Secondmate homes** - covered by construction: the seat key includes the realpath of `FM_HOME`, and `LAVISH_AXI_STATE_DIR` is per home, so a secondmate and its parent never share a seat or a session store despite sharing a UNIX account.
- **Hosts without tailscale** - covered by the loopback degradation path, the only branch where behaviour matches today's, apart from the honest warning.
- **Hosts without `jq`** - the allocator degrades to `reachability=loopback` with a reason, and the startup check stays silent.

## Validation record

Host `crew-hlr`, tailnet `tail7b8448.ts.net`, address `100.121.172.63`, UNIX account `coditan`, `lavish-axi` 0.1.43, 2026-07-30.

### Two vessels on one machine, no clash

Two scratch homes, no coordination between them, each opening a board through the wrapper:

```
$ FM_HOME=<scratch>/vesselA bin/fm-lavish.sh <scratch>/vesselA/.lavish/board.html --no-open
  url: "http://crew-hlr.tail7b8448.ts.net:4411/session/4cedced659385d92"
$ FM_HOME=<scratch>/vesselB bin/fm-lavish.sh <scratch>/vesselB/.lavish/board.html --no-open
  url: "http://crew-hlr.tail7b8448.ts.net:4484/session/7a4994b5c3bdd3fe"

$ ss -ltnH | awk '$4 ~ /:(44[0-9][0-9])$/ {print $4}'
100.121.172.63:4484
100.121.172.63:4411

$ curl -s -o /dev/null -w '%{http_code}' http://crew-hlr.tail7b8448.ts.net:4411/session/4cedced659385d92
200
$ curl -s -o /dev/null -w '%{http_code}' http://crew-hlr.tail7b8448.ts.net:4484/session/7a4994b5c3bdd3fe
200
```

Both bind the tailnet address only, on different ports, and both serve concurrently.

### The bind probe is authoritative across UNIX accounts

```
$ node bin/fm-service-port-probe.mjs bind 100.121.172.63 4388 4387 4392 4405
4405
$ node bin/fm-service-port-probe.mjs bind 100.121.172.63 4392 ; echo $?
3
$ node bin/fm-service-port-probe.mjs bind 10.9.9.9 4400 ; echo $?
fm-service-port-probe: cannot bind 10.9.9.9 on this host (EADDRNOTAVAIL)
4
```

4388 was this account's own server, 4387 and 4392 were held by other accounts, and 4392 was a wildcard bind - all three were correctly refused, and the unusable address was reported as exit 4 rather than as a collision.

### The claim token distinguishes our server from a neighbour's

```
$ curl -s -o /dev/null -w '%{http_code}' -H 'Host: crew-hlr'            http://100.121.172.63:4388/health
200
$ curl -s -o /dev/null -w '%{http_code}' -H 'Host: crew-hlr'            http://100.121.172.63:4392/health
403
$ curl -s -o /dev/null -w '%{http_code}' -H 'Host: fm-claim-testnonce123' http://100.121.172.63:4388/health
403
$ curl -s -o /dev/null -w '%{http_code}' -H 'Host: 127.0.0.1'           http://100.121.172.63:4392/health
200
```

4392 is another account's server, and it answers loopback identically to ours - which is exactly why loopback cannot be the discriminator and a per-home token can.

### A neighbour's server is refused, and the working board survives the refusal

Vessel B pointed at the port vessel A's server already holds, using the real wrapper end to end:

```
$ FM_HOME=<scratch>/vesselB FM_SERVICE_PORT_RANGE=4411-4411 bin/fm-lavish.sh <board> --no-open
SERVICE_PORT: no free port in 4411-4411 on 100.121.172.63 for lavish; every candidate is held by another process, ...
fm-lavish: the board already serving on port 4484 was left running, so nothing was lost
fm-lavish: no port is available for a review board on this vessel, so no board was opened
exit=5

$ ss -ltnH | awk '$4 ~ /:(44[0-9][0-9])$/ {print $4}'
100.121.172.63:4484
100.121.172.63:4411
$ curl -s -o /dev/null -w '%{http_code}' http://crew-hlr.tail7b8448.ts.net:4484/session/...
200
```

No adoption, no board, and vessel B's existing board still serving.
The first attempt at this design did stop B's own server before discovering the new port was unavailable, which is why the preserve-before-move rule above exists.

### Reuse, restart, and relocation

```
$ FM_HOME=<scratch>/vesselB bin/fm-lavish.sh <board> --no-open        # stale link host recorded
fm-lavish: the running board server was started with a different address configuration; restarting it so links are correct
  url: "http://crew-hlr.tail7b8448.ts.net:4484/session/..."           # same port reclaimed

$ FM_HOME=<scratch>/vesselB FM_SERVICE_PORT_RANGE=4470-4479 bin/fm-lavish.sh <board> --no-open
fm-lavish: moving this vessel's boards from port 4484 to 4474; links already handed over on the old port stop working
  url: "http://crew-hlr.tail7b8448.ts.net:4474/session/..."

$ FM_HOME=<scratch>/vesselB bin/fm-lavish.sh stop       # -> status: stopped, port: 4474
$ FM_HOME=<scratch>/vesselB bin/fm-lavish.sh stop       # -> nothing to stop
```

A second open of an unchanged board reuses the running server and leaves exactly one listener.

### The loopback readiness trap, reproduced

```
$ node bin/fm-service-port-probe.mjs http http://127.0.0.1:4411/health ; echo $?
fm-service-port-probe: http://127.0.0.1:4411/health did not answer (connect ECONNREFUSED 127.0.0.1:4411)
1
$ node bin/fm-service-port-probe.mjs http http://100.121.172.63:4411/health ; echo $?
200
0
```

The server on 4411 is healthy and serving throughout; loopback simply is not where it lives.

### Guard behaviour

```
$ bin/fm-lavish-pretool-check.sh --command 'lavish-axi board.html' ; echo $?
{"hookSpecificOutput":{...,"permissionDecision":"deny"},"systemMessage":"[bare-lavish-axi] ..."}
{"decision":"deny","reason":"[bare-lavish-axi] ..."}
2
$ bin/fm-lavish-pretool-check.sh --claude --command 'lavish-axi board.html' >/dev/null ; echo $?
2
$ bin/fm-lavish-pretool-check.sh --command 'bin/fm-lavish.sh board.html' ; echo $?
0
$ FM_ROOT_OVERRIDE=/tmp bin/fm-lavish-pretool-check.sh --command 'lavish-axi x.html' ; echo $?
0
```

Claude's `--claude` deny leaves stdout empty, Grok's stdin shape returns the stdout decision object, and a checkout without the wrapper is inert.
`tests/fm-lavish-access.test.sh` owns the full acceptance matrix.

### The userspace-mode vessel

Measured 2026-08-27 on `coditan-vessel` (tailscale node `coditan-vessel.tail7b8448.ts.net`, address `100.73.181.90`), a container whose tailscale runs in userspace mode.

The condition, and that it is address-scoped rather than port-scoped:

```
$ ls -l /dev/net/tun
ls: cannot access '/dev/net/tun': No such file or directory
$ ip -4 addr show | grep -E '^[0-9]+:'
1: lo: <LOOPBACK,UP,LOWER_UP> ...
2: eth0@if431: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
$ node bin/fm-service-port-probe.mjs addr 100.73.181.90
fm-service-port-probe: cannot bind 100.73.181.90 on this host (EADDRNOTAVAIL)
$ echo $?
4
```

`CapBnd` was `00000000a80425fb`, whose bit 12 (`CAP_NET_ADMIN`) is clear.
No `tailscale0` interface exists, so the address the node advertises is carried by nothing local.

Before this change, `bin/fm-lavish.sh` opened no board at all on this vessel: `bin/fm-service-port.sh` exited 3 with `100.73.181.90 cannot be bound on this host`, and the wrapper reported `no port is available for a review board on this vessel`.

The Host header a browser sends through the proxy, measured with an echo server rather than inferred:

```
$ tailscale serve --bg --http=4479 http://127.0.0.1:4479
$ curl -s -o /dev/null -w '%{http_code}\n' http://coditan-vessel.tail7b8448.ts.net:4479/
200
# the echo server's own log line for that request:
HOST=coditan-vessel.tail7b8448.ts.net:4479 XFH=coditan-vessel.tail7b8448.ts.net:4479 URL=/
```

The name, not loopback and not the address, and carrying the published port.
Reading the installed `lavish-axi` (`isAllowedHostHeader`) confirms the allowlist is compared on `authority.hostname`, so the port the proxy adds is not part of the question.

A board opened end to end through the entry point:

```
$ FM_HOME=/home/coditan/coditan-firstmate bin/fm-lavish.sh /tmp/.../probe-board.html
fm-lavish: this node has the tailnet address 100.73.181.90 but no local interface carries it
  (bind fails EADDRNOTAVAIL), which is what tailscale userspace networking mode looks like;
  the port is bound on loopback and published onto the tailnet address with tailscale serve instead
session:
  url: "http://coditan-vessel.tail7b8448.ts.net:4451/session/9aca2df349accd0a"
  status: opened
```

Fetched over the tailnet name rather than over loopback, and returning the board's own content:

```
$ curl -s -w 'HTTP=%{http_code} via=%{remote_ip}\n' \
    http://coditan-vessel.tail7b8448.ts.net:4451/session/9aca2df349accd0a -o got.html
HTTP=200 via=100.73.181.90
$ wc -c got.html
16800 got.html
$ grep -o 'userspace tailnet probe board' got.html
userspace tailnet probe board
```

#### That 200, on its own, does not prove the proxy carried it

This is the trap, and it was walked into during this work before being caught.

A request made **from this container** to this node's own tailnet address reaches a loopback listener whether or not any proxy is published.
Measured with a port bound only on `127.0.0.1` and published nowhere:

```
$ tailscale serve status | grep -c 4477
0
$ curl -s -o /dev/null -w '%{http_code}\n' http://100.73.181.90:4477/
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.28.0.2:4477/     # eth0's own address
000
```

So an on-host `curl` returning 200 over the tailnet name is not by itself evidence of the proxy, and must never be reported as such.

The discriminator is `X-Forwarded-Host`, which `tailscale serve` sets and the same-host path does not.
Same URL, same listener, proxy withdrawn and then published, as the echo server behind it logged each request:

```
proxy down: HOST=coditan-vessel.tail7b8448.ts.net:4477 XFH=
proxy up:   HOST=coditan-vessel.tail7b8448.ts.net:4477 XFH=coditan-vessel.tail7b8448.ts.net:4477
```

That is what proves the proxy path works, and it is the reading any future on-host check has to take.
A remote peer has no such same-host shortcut: for it, the published proxy is the only listener on that address.

The poll path, driven from a real browser over that same link.
`chrome-devtools-axi` could not be used - every command, `open` included, answered `error: No page is currently selected / code: BROWSER_ERROR` - so headless Chrome 152.0.7977.64 was driven directly over CDP instead.
The page loaded the real Lavish UI (`document.title` = `userspace tailnet probe board · Lavish`, with its `Send to Agent` composer present), text was typed into the composer through the native value setter plus an `input` event, and the button was clicked:

```
$ bin/fm-lavish.sh poll /tmp/.../probe-board.html
prompts[1]{uid,prompt,selector,tag,text}:
  "","FM_POLL_PROOF: queued from a real browser over the tailnet name","",message,Freeform message
```

Teardown, and what it prevents:

```
# with the proxy left standing after the board stops
$ curl -s -o /dev/null -w 'HTTP=%{http_code}\n' http://coditan-vessel.tail7b8448.ts.net:4451/health
HTTP=502
# after bin/fm-lavish.sh stop withdraws it
$ tailscale serve status        # the 4451 entry is gone
$ curl -s -o /dev/null -m 6 -w 'HTTP=%{http_code}\n' http://coditan-vessel.tail7b8448.ts.net:4451/health
HTTP=000
```

The fallback firing only where it should is held by `tests/fm-lavish-access.test.sh`, hermetically: a fake tailscale in `userspace` mode reports `192.0.2.1` (TEST-NET-1, assigned on no host, so the bind genuinely fails rather than being mocked into failing), and the fake `tailscale serve` logs every invocation.
A bindable address stays `reachability=tailnet` with an empty serve log; a host with no tailnet at all keeps its existing loopback behaviour and message with an empty serve log; and an unbindable address whose serve cannot publish degrades to loopback rather than claiming reach.

### Open gap: the off-device request

Acceptance asked for an HTTP 200 fetched from a different device on the tailnet.
That was not completed from this task's worktree, and it was not completed from `coditan-vessel` either when the proxied path was added on 2026-08-27.
Every peer refuses SSH from this seat - `tailscale ssh` reports no advertised SSH host key for `crew-hlr`, `aurora`, `coditan`, `crew-allesknut`, `tugboat-cloud`, or `timbook-wsl`, and plain `ssh` answers `Permission denied (publickey)` for each - so no command can be run on another node to make the request.

What was proved instead is everything on this side of the wire: the server binds only the tailnet address (loopback is refused), the emitted hostname resolves to that address, a request carrying the tailnet name is accepted by the Host allowlist and returns 200, and `tailscale ping timbook` answers directly.
The remaining check is one request from the captain's PC or phone against a link the wrapper emits.
The phone is the one worth doing specifically: the MagicDNS name carries both an A and an AAAA record while Lavish binds one address, so a v6-preferring client reaches a closed port first and has to recover through Happy Eyeballs.

## Related

- `docs/fleet-service-port-registry.md` - the cross-vessel published-record proposal, which is a proposal and not binding.
- `docs/cd-guard.md`, `docs/arm-pretool-check.md`, `docs/subagent-guard.md` - the sibling PreToolUse guards this one follows.
