<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated firstmate homes.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, tracked harness hooks and profiles, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it instantiates your first mate - and makes you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own tmux window, experimental herdr/zellij tab, cmux workspace, or Orca terminal you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver a change; scout tasks investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **Optional secondmates** - opt in to persistent second mates that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, supervising project clones or a project-less firstmate-repo domain, kept on the primary firstmate version by guarded local fast-forwards and checked for live agent processes at session start.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and a companion service delivers the wake, both outside the agent harness so neither can be killed with a session; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is under way and supervision is not live.
- **Optional X mode** - opt in with one local `.env` token so firstmate can answer your public `@myfirstmate` mentions, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-X behavior; dry-run preview records would-be replies and dismissals locally before go-live.
- **Guarded by construction** - the first mate is read-only over your projects except for the guarded paths authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), with fleet sync's safe branch pruning remaining part of the fleet-sync exception; crewmates make every project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected); kill the session anytime and the next one reconciles, including confirmed-dead secondmate agents, and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- A verified agent harness: Claude Code, Grok, Pi, Codex, or OpenCode.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- tmux, for the reference session backend.

The first mate detects and offers to install everything else.

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary firstmate session.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Codex and OpenCode are also verified and supported as primary harnesses.
Wake delivery itself no longer differs between them: it runs as a service outside every harness, so a session holds no delivery object and there is no per-harness wake mechanism to trade off ([docs/wake-delivery.md](docs/wake-delivery.md)).

### Install and launch

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

Then launch one of the co-primary harnesses; AGENTS.md takes over from there:

**Claude Code**

```sh
PATH="$PWD/.local/axi/bin:$PATH" claude
```

**Grok**

```sh
PATH="$PWD/.local/axi/bin:$PATH" grok --trust
```

**Pi**

```sh
PATH="$PWD/.local/axi/bin:$PATH" pi
```

The prefix directory may be absent on first launch; keeping it first from process start makes the vessel-owned AXI copies take precedence as soon as bootstrap installs them.
When `FM_HOME` differs from the checkout root, prepend `$FM_HOME/.local/axi/bin` instead.
Codex and OpenCode use the same PATH assignment before their `codex` or `opencode` launch command.

That prefix has to be remembered at every launch, and a launch without it leaves the maintained copies installed but never run by your own shells - which `AXI_SUITE_SHADOWED:` reports rather than repairs, because your login environment is yours to change and not firstmate's.
If you would rather resolve it once, append these four lines to the end of your bash login profile (`~/.profile`):

```sh
fm_axi_dir=$(. /path/to/this/checkout/bin/fm-axi-path-lib.sh && fm_axi_bin_dir)
case "$PATH" in "$fm_axi_dir"|"$fm_axi_dir":*) fm_axi_dir= ;; esac
[ -n "$fm_axi_dir" ] && PATH="$fm_axi_dir:$PATH" && export PATH
unset fm_axi_dir
```

Put them last so they win over earlier `PATH` edits, and write the checkout's real path rather than a variable.
Every shell of that home then resolves its own maintained copies, including after a restart.
Take the form as written: the subshell keeps the library's functions out of your login shell, and the emptiness test is what keeps a shell that cannot locate the sourced file from prepending an empty `PATH` entry, which POSIX reads as the current directory.
The `case` asks whether the maintained directory is already `PATH`'s FIRST entry, which is the same question `fm_axi_prepend_path` asks: re-reading the profile in a shell that already leads with it stacks no second copy, while a shell where something else has since jumped ahead re-asserts priority instead of leaving the older copy resolving.
Use `fm_axi_bin_dir` rather than the library's own `fm_axi_prepend_path` here: that function records the pre-prepend `PATH` as the session's ambient one, so a profile calling it makes the currency check report a shadow your shells are not actually running ([docs/configuration.md](docs/configuration.md) "AXI-suite self-update" owns that measurement).
Each home picks its own prefix from `FM_HOME`, falling back to the sourced file's checkout, so two homes on one machine do not compete.
Self-location needs `BASH_SOURCE`, so in zsh, dash, or any other shell without it the bare call prints nothing and the lines leave `PATH` untouched; there, name the home explicitly as `fm_axi_bin_dir /path/to/home`.
Only command names that exist inside that prefix are affected, so anything you installed elsewhere resolves exactly as before, and a home whose prefix does not exist yet is unaffected until the currency check creates it.
This is optional, and nothing in firstmate writes or reads your profile: verify it by effect from a new shell with `command -v gh-axi` and `gh-axi --version`, not by reading the file back.
For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too.
For Pi, approve the project trust prompt once per clone on first launch so the tracked `.pi/extensions/*.ts` files auto-load.
Every Pi session starts with calm mode off; `/calm` is a session-local conversation-focused transcript toggle.
While active, it uses Pi's supported presentation APIs to hide the live working row, collapsed thinking labels, all seven built-in tool shells, and canonically typed Firstmate operational inputs.
Every injected input remains in model context and session storage.
Inputs that ordinarily render as user rows use a TUI-only custom entry so Calm can hide and restore their presentation without changing delivery; the session-start nudge remains on its existing non-displayed custom-message path.
Toggling off restores ordinary rendering, and `Ctrl+O` expansion behavior stays unchanged.
Tool execution, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged; Pi's exporter omits synthetic control inputs because its supported renderer surface cannot preserve their stock user styling without leaving live transcript gaps.
Pi 0.81.1 still exposes no global transcript filter, so expanded reasoning, its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, status notices, and arbitrary custom-tool or extension rows remain supported-API boundaries.
The version-scoped feasibility evidence and complete render taxonomy are recorded in [docs/calm-mode-feasibility.md](docs/calm-mode-feasibility.md).

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in the active backend
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Optional secondmates extend this to persistent second mates, dispatch profiles let you steer which harness handles which task, and an opt-in X mode lets the same fleet answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional X mode, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine notifications in bash, escalates captain-relevant events and bounded declared-external-wait rechecks as batched digests, and actively alerts if delivery gets stuck while you step away |
| `/ahoy`            | Recap only visible session events since the prior real captain message, falling back to Bearings when invoked as the session's first real captain message |
| `/bearings`        | Generate a standalone current-status report from bounded local fleet and registered-secondmate state, with live PR enrichment only when requested, written to a dated file in `data/` and surfaced concisely in chat; read-mostly, mutates no task state |
| `/decisionboard`   | Lay every captain-actionable decision out as one visual board: duplicates from panels collapsed into single decisions, the gating structure between them made visible, and each one answerable in place. Reads the structured decision record only; never answers or alters a decision itself. Not every open captain decision reaches it - one blocked by another record leaves the actionable surface, so the board cannot show it. The fleet-wide standing inbox; for one undertaking against its own destination use `/sea-chart`. |
| `/sea-chart`       | Lay one named undertaking out as a chart: its destination, what is decided, what is takeable now, its fog, and the boundaries deliberately outside its course. Reconciles its own decision records against the backlog so a withheld one is counted rather than silently dropped, and prints its own incompleteness. Read-only; the per-undertaking counterpart to `/decisionboard`. Amends the Wayfinder skill by Matt Pocock (MIT) - see [`docs/sea-chart-provenance.md`](docs/sea-chart-provenance.md). |
| `/to-backlog`      | Break a plan, spec, scout report, or the conversation into backlog items: each a tracer bullet cutting a complete path through every layer, each sized to one crewmate session, each declaring what must land before it. Quizzes you on granularity and dependencies before anything is filed, then files blockers-first under the originating undertaking's id so the units land on its `/sea-chart`. Adopts the to-tickets skill by Matt Pocock (MIT) - see [`docs/to-backlog-provenance.md`](docs/to-backlog-provenance.md). |
| `/domain-modeling` | Sharpen the terms a piece of work runs on and record its decisions in passing: challenge a word doing two jobs, force a boundary precise with a concrete scenario, check a claim against the artifact rather than against memory, and write the resolution where the next reader meets it. Carries the rule that a domain's proper nouns are never translated. Routes into the stores that already exist and creates none of its own. Adopts the domain-modeling skill by Matt Pocock (MIT) - see [`docs/domain-modeling-provenance.md`](docs/domain-modeling-provenance.md). |
| `/grossreinschiff` | Run the weekly Thursday cleanup sweep: nine places where records, instructions, branches, tools, and workspaces stop being true, each finding carrying the test behind its verdict and the evidence to re-measure it. Reports only - deletion is a separate captain-authorized step, and inside a project a dispatched worker's task. Never judges landedness by ancestry, since the fleet's history contains squash merges and callers can still request them, and always states what it did not cover. Due automatically at the first session start on or after Thursday; see [`docs/grossreinschiff.md`](docs/grossreinschiff.md). |
| `/codebase-sweep`  | Sweep one named repository for codebase-design findings, classify each by what a wrong fix would cost and whether anyone would find out, sort them by tier and then by how many other findings each unblocks, and go ahead through the project's own delivery path with the ones that are reversible without you and contained inside one module. One repository at a time and never fleet-wide, since it never reaches into homes this seat does not own. The three risk tiers are your framing and no source's - the talk it is grounded in defines no risk scale of any kind, measured against its full transcript; see [`docs/codebase-sweep-provenance.md`](docs/codebase-sweep-provenance.md). |
| `/design-it-twice` | Design one module's interface more than once, compare the shapes on depth, locality, and seam placement, and recommend one. Does the exercise in one head by default and reaches for `/panel` only when several shapes are defensible and the choice would change what ships, so the offer keeps carrying information. Never substitutes ad-hoc parallel sub-agents for the panel: sub-agents on one harness default all run the same model, so their agreement is one model's priors repeated and nothing tells you. Adapts the DESIGN-IT-TWICE.md half of the codebase-design skill by Matt Pocock (MIT) - see [`docs/design-it-twice-provenance.md`](docs/design-it-twice-provenance.md). |
| `/panel`           | Run a model panel on one question: two analysts investigate independently on different models without seeing each other's work, then a third model judges both and re-verifies their load-bearing claims; refuses rather than presenting two runs of one model as independent |
| `/run-fleet-update` | Take this vessel's own currency reading across all three hops - level with its own origin, the pin it carries, and how far that pin lags the source the pin names - reported separately and never collapsed into one word. A hop it could not measure reads as unmeasurable rather than as current. Measures only; taking an update stays a separate authorized step. Also runs by itself as the `pin-age` subject of the daily currency round; see [`docs/pin-age-check.md`](docs/pin-age-check.md). |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to whatever their own origin already carries, with fast-forward-only pulls, then re-read instructions and nudge secondmates. Answers the own-origin hop alone, and on a pin-delivered home that hop stops at the pin, so `/run-fleet-update` remains the currency reading. Names when a pin bump is the real next step and whose reviewed work that is; it never bumps a pin itself. |
| `/stow`            | Sweep the session for uncaptured durable knowledge, route each finding to its disk home per AGENTS.md, file undone next steps to the backlog, and report what is now safe to reset |

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every skill written here assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
  The exception is a skill *installed* here from upstream rather than written here, which carries upstream's frontmatter unchanged and is generally useful outside a firstmate home.
  `skills-lock.json` records which ones those are, and they are never edited to match the local convention - see [`docs/axi-skill-provenance.md`](docs/axi-skill-provenance.md).
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback in the current directory, and closes with a resume pointer for the next session.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, worktrees, secondmates, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional X mode, Codex profile and Graphify hook configuration, the files you set, and harness support.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - setup guide for the tmux reference backend: prerequisites, attaching, and watching crew windows.
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup guide for the experimental herdr backend, plus its verification notes and known gaps.
- [docs/zellij-backend.md](docs/zellij-backend.md) - setup guide for the experimental zellij backend, plus its verification notes and known gaps.
- [docs/orca-backend.md](docs/orca-backend.md) - setup guide for the experimental Orca backend, plus its lifecycle notes and known gaps.
- [docs/cmux-backend.md](docs/cmux-backend.md) - setup guide for the experimental cmux backend, plus its verification notes and known gaps.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - Codex App backend boundary, evidence, and rollout contract.
- [docs/codex-busy-detection.md](docs/codex-busy-detection.md) - Codex 0.145.0 busy-row evidence behind the watcher liveness backstop.
- [docs/codex-status-signalling.md](docs/codex-status-signalling.md) - why Codex direct reports get a per-task writable status-signal directory, how the public status paths stay stable, and what live evidence led to the split.
- [docs/codex-completion-gate.md](docs/codex-completion-gate.md) - why a sandboxed Codex worker could not close the unresolved-decision completion gate, why earlier scouts closed theirs, and where the completion attestation is written now.
- [docs/codex-sandbox-network.md](docs/codex-sandbox-network.md) - why a Codex crewmate carries a sandbox network grant to reach the local no-mistakes daemon socket, what that whole-dimension grant admits, and why it rides the launch line rather than the tracked Codex profile.
- [docs/codex-sandbox-git-directory.md](docs/codex-sandbox-git-directory.md) - why a Codex crewmate carries its linked worktree's git common directory as a writable root, what repository-wide writes that admits, and why the project working tree stays refused.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - how the merge watch follows a GitLab merge request on any instance, and the evidence behind it.
- [docs/merge-gate-audit.md](docs/merge-gate-audit.md) - how to audit GitHub merge gates across rulesets and classic branch protection, including the historical heavyliftrental fleet gate map.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's structural "no turn ends blind" backstop: verified per-harness hook mechanisms, scoping, loop safety, and fail-open tradeoffs.
- [docs/context-reset.md](docs/context-reset.md) - the stow-then-clear context ceiling: what the watcher measures, when it resets, asks, blocks, or reports itself unenforced, and every refusal the reset tool makes.
- [docs/wake-delivery.md](docs/wake-delivery.md) - how a queued wake becomes a model turn: the external listener, why no session holds a delivery object, and the verdict that keeps a dead listener from looking like a quiet fleet.
- [docs/seat-respawner.md](docs/seat-respawner.md) - how a dead primary seat is relaunched, how to declare an intentional stay-down, and why manual close without that marker brings the seat back.
- [docs/session-archive.md](docs/session-archive.md) - the searchable session archive: a reduced, redacted, compressed, per-vessel derivative of this machine's own transcripts, why a full content scan is the index, why a wrong reader is made loud, and the honest bound that travels with every claim made from it.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness supervision protocols for Claude, Codex, OpenCode, Pi, Grok, and unknown harness fallback.
- [docs/supervision-cost.md](docs/supervision-cost.md) - what supervision costs in freshly written tokens, measured from provider usage records with `bin/fm-supervision-cost.sh`, plus the before-and-after for three repairs and what the measurement does not cover.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [`AGENTS.md`](AGENTS.md) - the distro's always-loaded operating contract and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).

Third-party material, all from [`mattpocock/skills`](https://github.com/mattpocock/skills) by Matt Pocock and used under the MIT licence:

- `/sea-chart` and `bin/fm-sea-chart.sh` amend the Wayfinder skill. [`docs/sea-chart-provenance.md`](docs/sea-chart-provenance.md) carries that copyright notice and licence text, along with what was kept, changed, and dropped.
- `/to-backlog` and `bin/fm-to-backlog.sh` adopt the to-tickets skill. [`docs/to-backlog-provenance.md`](docs/to-backlog-provenance.md) carries the same notice and licence text, along with what was kept, changed, and dropped with the cost of each omission.
- `/domain-modeling` adopts the domain-modeling skill. [`docs/domain-modeling-provenance.md`](docs/domain-modeling-provenance.md) carries the same notice and licence text, along with what was kept, changed, and dropped with the cost of each omission.
- `/design-it-twice` adopts one file of the codebase-design skill, its `DESIGN-IT-TWICE.md`, and not the vocabulary the rest of that skill owns. [`docs/design-it-twice-provenance.md`](docs/design-it-twice-provenance.md) carries the same notice and licence text, what was kept, changed, and dropped with the cost of each omission, and why only half of that skill is on this side of the line.
- `scout-research` forks the research skill, because that skill's opening step - spin up a background agent - is refused in a firstmate primary home. [`docs/scout-research-provenance.md`](docs/scout-research-provenance.md) carries the same notice and licence text, what was kept, changed, and dropped with the cost of each omission, the measurement behind the fork, and how a reader chooses between this skill and the plugin it forks.

Third-party material from a different upstream, on different terms:

- `.agents/skills/axi/` is the official AXI skill by Kun Chen, from [`kunchenguid/axi`](https://github.com/kunchenguid/axi), used under the MIT licence.
  It is installed verbatim through `npx skills add` rather than adapted, so it is never edited here and this repository's own Markdown conventions do not apply to it.
  [`docs/axi-skill-provenance.md`](docs/axi-skill-provenance.md) carries that copyright notice and licence text, records the installed commit and content hash, and states why the file stays untouched; `.agents/skills/axi/LICENSE` carries the notice beside the copy itself.
  This fleet's own additions, which the AXI specification does not cover, live separately in `.agents/skills/axi-tool-intake/` and restate none of it.

`/codebase-sweep` is not on that list: it loads the `codebase-design` plugin skill and copies nothing from it, and its sweep subjects are traced to a talk by the same author rather than derived from his code. [`docs/codebase-sweep-provenance.md`](docs/codebase-sweep-provenance.md) records what came from that talk, what did not, and the measurement behind the difference.
That still holds beside the `/design-it-twice` entry above: the adoption of that plugin skill's `DESIGN-IT-TWICE.md` belongs to `/design-it-twice`, and `/codebase-sweep` continues to reach the vocabulary through the plugin and to copy none of it.

Operational provenance records for installed local tools and Codex-managed bundles that are not vendored into this repository live in [`docs/provenance-metadata-followups.md`](docs/provenance-metadata-followups.md).
