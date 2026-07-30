# Reachable review boards

Lavish review boards are how firstmate hands the captain a decision surface.
A bare `lavish-axi` binds loopback and writes `http://127.0.0.1:<port>/...` into the link it hands over, which opens nothing on his PC or phone.
The failure is silent: the board renders correctly on the machine that made it, so nothing signals that the link is dead everywhere else.

`bin/fm-lavish.sh` is the entry point that fixes it, `bin/fm-service-port.sh` is the general port allocator underneath it, and `bin/fm-lavish-pretool-check.sh` is the guard that stops an agent reaching for the old command out of habit.
Each script's header owns its exact flags and mechanics; this document owns the contract between them, the reasoning, and the validation record.

## Why this could not be a documented environment variable

`~/.bashrc` returns immediately for non-interactive shells, and an agent tool shell loads its own snapshot instead, so an operator's profile export never reaches an agent's invocation.
That route had already been tried here and had already failed once: the problem was written onto a review board, and the link to that same board went out on loopback.
The fix therefore has to be a firstmate-owned mechanism that is hard to bypass by habit, not a note somebody has to remember.

## What the entry point sets

| Variable | Value | Why |
| --- | --- | --- |
| `LAVISH_AXI_HOST` | this vessel's tailnet IPv4 address | reachable off this machine, and never a wildcard, because an all-interfaces bind is broader than was approved |
| `LAVISH_AXI_PORT` | a port proved free by `bin/fm-service-port.sh` | vessels sharing one machine do not collide |
| `LAVISH_AXI_LINK_HOST` | the tailnet DNS name, but only once it has been confirmed to resolve to the bound address; otherwise the address | the hostname the captain actually receives is checked before he receives it |
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

Stopping reaches into a running process the same way, so it carries the same proof, and an explicitly named port is no exception.
`lavish-axi stop` shuts down whatever answers `/health` with a lavish-axi body on the address it is handed, without authentication and without regard for the owning UNIX account, and every co-hosted vessel binds that same address.
So `bin/fm-lavish.sh stop --port <n>` runs the claim-token probe against `<n>` before it reaches `lavish-axi` at all: a port that answers but is not this home's is refused by name and left running, and a port that answers nothing is reported as nothing to stop.

A port outside the currently resolved window counts as the same kind of staleness: an operator who narrows `FM_SERVICE_PORT_RANGE` to move this service off a conflict would otherwise keep the old port forever, because it is still legitimately ours.
The two cases are handled differently on purpose.
When the same port is still wanted, the old server is stopped first so the seat can be reclaimed immediately.
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
- **The link host does not answer after the board opens** - the wrapper names the address form that does work.
- **Every candidate port is taken** - `bin/fm-service-port.sh` exits non-zero with one plain sentence and no board is opened.
  There is deliberately no silent loopback downgrade here, because that would reproduce the original bug somewhere new.
- **The address cannot be bound at all** - a distinct exit code and message, because that is a network-interface problem and reporting it as a port collision would send the reader hunting the wrong thing.
  Only address-scoped errnos (`EADDRNOTAVAIL`, `EAFNOSUPPORT`, `EINVAL`) count as this, and they are the only ones that end the walk early, since no port on that address could have worked.
  A port-scoped refusal such as `EACCES` on a privileged port is neither a collision nor an unusable address: the walk continues past it, and only if nothing in the window binds does the allocator report that some candidates were held and others refused.

A readiness probe must target the address that was bound.
Probing loopback while a service binds only a tailnet address reports a healthy server as failed to start; that happened during this investigation and cost real time.
`bin/fm-service-port-probe.mjs http` exists so callers cannot get this wrong by accident.

### The wrapper observes rather than predicts

Every one of those sentences is about a board, so the wrapper says none of them until it has seen a board.
It decides that from a session URL in what the run printed, not from the shape of the arguments it was given.

The reason is that argument shapes cannot answer the question.
`lavish-axi` dispatches `open` for `--help <board>.html` and for `open --help`, and then its CLI layer returns the command's help text without ever calling the handler, so an invocation that dispatches `open` can still open nothing.
Predicting that from argv means keeping a copy of somebody else's argument handling and getting it wrong on the next shape, which is what happened twice here before this rule replaced it.
Observation has no such failure mode: no session URL means no link exists, and silence is the only honest thing to say about a link that does not exist.

Two things still have to be decided before the run, and are therefore still decided from the arguments.
The port claim comes first because a port has to exist before the command can run at all, so `bin/fm-lavish.sh open --help <board>.html` does take a port from the window and does rewrite `state/service-port.lavish` and `state/lavish/fm-owner`, and can restart or relocate this vessel's own server on the way.
That is the wrapper's ordinary open bookkeeping against its own home rather than a false statement to the captain, and closing it would mean running the command before knowing what port to run it on.
The other is a command that replaces this process with `lavish-axi` (`poll`, `end`, `server`): nothing after an `exec` can observe anything, so those emit their degradation notice up front.

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

### Open gap: the off-device request

Acceptance asked for an HTTP 200 fetched from a different device on the tailnet.
That was not completed from this task's worktree: the two other Linux nodes (`aurora`, `crew-allesknut`) refuse SSH with `Permission denied (publickey,password)` and do not advertise a Tailscale SSH host key, and the captain's own `timbook` and `s26-ultra-von-tim` cannot be driven from here.

What was proved instead is everything on this side of the wire: the server binds only the tailnet address (loopback is refused), the emitted hostname resolves to that address, a request carrying the tailnet name is accepted by the Host allowlist and returns 200, and `tailscale ping timbook` answers directly.
The remaining check is one request from the captain's PC or phone against a link the wrapper emits.
The phone is the one worth doing specifically: the MagicDNS name carries both an A and an AAAA record while Lavish binds one address, so a v6-preferring client reaches a closed port first and has to recover through Happy Eyeballs.

## Related

- `docs/fleet-service-port-registry.md` - the cross-vessel published-record proposal, which is a proposal and not binding.
- `docs/cd-guard.md`, `docs/arm-pretool-check.md`, `docs/subagent-guard.md` - the sibling PreToolUse guards this one follows.
