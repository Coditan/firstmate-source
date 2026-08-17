# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, and scout reports.
`state/` holds volatile runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, away-mode state, generated X-mode artifacts, private secondmate config-reread generations with their retry and quarantine state, and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`.local/axi/` is the home-private npm prefix for the managed AXI CLI suite.
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Firstmate reads but changes only through the guarded exceptions in `AGENTS.md`.

A home's checkout also accumulates runtime artifacts that a supported harness or firstmate writes into the tracked tree itself: Claude Code's local permissions and settings file plus its scheduler, routine, worktree, checkpoint, mailbox, agent-registry, agent-memory, first-run, and daemon state, firstmate's generated per-task hook overlay, and - whenever the home is the checkout root - the `.local/axi/` prefix above.
The tracked root `.gitignore` owns the exact path list and is the only correct place for it: `dirty_status` in `bin/fm-ff-lib.sh` reads `git status --porcelain`, which reports untracked files too, so any of those artifacts would otherwise make a vessel dirty and silently drop it out of every guarded fast-forward, and a clone-private `.git/info/exclude` cannot carry the rule because a fresh clone does not inherit one.
The patterns stay narrow so the tracked `.claude/settings.json` and the tracked `.claude/skills` symlink remain visible to `git add`, and `tests/fm-runtime-ignore.test.sh` proves in a fresh clone that every artifact form is ignored by the tracked `.gitignore` rather than a private or global exclude, that the tracked paths are not, and that `.claude/settings.local.json` is never tracked.

Captain-private material is ignored by directory- and prefix-wide rules rather than by naming files one at a time, because an enumerating list fails open for every private file added after it was last edited.
The list had drifted exactly that way: `config/telegram.env` and `config/fm-tg-recv.sh` were documented as local and gitignored while no rule covered them, so a plain `git add -A` in a home with the direct Telegram receiver enabled would have staged a working bot token into this shared template.
The rule is `config/*` rather than `config/` so a config file that genuinely must be shared can still be re-included with an explicit negation; nothing under `config/` is tracked today, and tracking one has to be a deliberate edit.
`tests/fm-private-material-ignore.test.sh` proves in a fresh clone that a private file invented after those rules were written is still ignored by the tracked `.gitignore`, that the negation escape hatch works, that no captain-private material is tracked, and - the opposite direction, which a rule broad enough to swallow the repository would otherwise pass - that no tracked file is hidden from `git add` by the shared ignore.
Editing `.gitignore` therefore selects every suite that asserts against the tracked ignore rules under `bin/fm-test-run.sh --changed`, not only the two ignore suites: a config suite that checks its own local file is ignored takes the same dependency, and such a suite going unselected is what turned this change's first validation run red.
The `.gitignore` arm of the changed-file map in `bin/fm-test-run.sh` is the single owner of that list, and that sentence is an invariant the suite enforces rather than a promise someone has to remember: `tests/fm-test-run.test.sh` scans every other suite for a call to the `tests/lib.sh` ignore helpers or a read of `$ROOT/.gitignore` and fails when one of them is not selected by a `.gitignore` edit.
A suite that takes the dependency in some third form no grep can see is the one case the guard cannot catch, so add it to the arm by hand.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and X helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, direct Telegram receiver, away-mode, and X-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

Vessel-local service reachability uses `state/service-port.<service>` for the address and port one service took, and `state/lavish/` for this home's private review-board server state, session store, and claim token.
`bin/fm-service-port.sh` owns the record's fields and the allocation contract, and `docs/lavish-access.md` owns the reasoning; the one rule that binds every reader is that the record is a published fact written after the fact and never a reservation, so nothing may read it to decide whether a port is free.
Several vessels can share one machine as separate UNIX accounts, so a successful bind is the only proof a port is available.

Watcher coordination uses `state/.watch.lock` for the daemon pid, executable, home, manager, source, and X-mode identities plus the keeper tier's handed-down service `PATH`, `state/.last-watcher-beat` for daemon freshness, `state/.wake-queue` for durable delivery, and `state/.wake-queue.lock` for atomic append and drain.
Delivery coordination is the companion service's, in the same shape: `state/.delivery.lock` for the listener pid, executable, home, manager, and source identities, `state/.last-delivery-beat` for listener freshness, and `state/.primary-endpoint` for the address the locked session published (docs/wake-delivery.md).
The tmux fallback also records `state/.watch-keeper.pid`, while systemd convergence writes the private mode-`0600` `state/.watch-service.env` environment file.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`docs/sessionstart-nudge.md` owns the native session-open adapter mechanics that nudge the digest command.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Vessel role (config/role / roles/)

This section is the single owner of the vessel-role contract; `bin/fm-role-lib.sh`'s header owns the resolution mechanics and `roles/<name>.md` owns each role's own instructions.

A role is configuration, not a codebase.
Every fleet member runs the same tracked code root, and the local, gitignored `config/role` file selects which tracked `roles/<name>.md` overlay amends `AGENTS.md` for that one home.
The recognized values are `vessel`, `coordinator`, and `executor`.
`vessel` is the default and is also the meaning of an absent file: no overlay, `AGENTS.md` unamended, and no role-related output anywhere in a session.
`roles/vessel.md` deliberately does not exist, because "no amendment" is not a document.
`coordinator` relays captain authority to peer vessels and routes across their domains; [`roles/coordinator.md`](../roles/coordinator.md) owns what that means.
`executor` runs the fleet's work where it lives - deploying, watching, and delivering - and hands another vessel's domain back to that vessel to diagnose; [`roles/executor.md`](../roles/executor.md) owns what that means.

The value is the first non-empty line of the file with whitespace stripped, exactly like `config/backend`.
There is deliberately no `FM_ROLE` environment override: the role is a property of the home, not of a session, and a session-level variable is precisely what would relax the spawn refusal below.
An unrecognized value emits `ROLE_INVALID: <name> (known: <names>)` at session start and delivers no overlay, rather than silently falling back to `vessel`.
A recognized non-default role whose overlay file is absent from this code root emits `ROLE_OVERLAY_MISSING: <name> (expected: roles/<name>.md)`, because a selected role that cannot be delivered is a misconfiguration, not a default.
[`bootstrap-diagnostics`](../.agents/skills/bootstrap-diagnostics/SKILL.md) owns the handling of both lines.

Delivery uses two seams that already existed, and no new instruction-include mechanism.
`bin/fm-session-start.sh` prints the active overlay at the head of its context digest, the same channel that already carries `data/captain.md`, which gives deterministic delivery at every session start.
`AGENTS.md`'s own load line tells an agent to load `roles/<name>.md` when `config/role` names a role, which gives persistence after context compaction.
Both are deliberate: the digest is authoritative at startup, the instruction line survives a context reset.
`AGENTS.md` itself is never swapped per role, because CI hard-requires the `CLAUDE.md -> AGENTS.md` symlink.
`roles/` is tracked instruction surface alongside `AGENTS.md`, `bin/`, and `.agents/skills/`, so an overlay change fast-forwards to running homes and counts as an upstream instruction update.

`config/role` is deliberately NOT in the inheritable set that `bin/fm-config-inherit-lib.sh` declares, exactly like `config/secondmate-harness`.
A coordinator's secondmate is not itself a coordinator, and inheriting the role would silently spread a no-crew posture into homes that need crews.

Enforcement is one refusal: `bin/fm-spawn.sh` refuses a ship or scout spawn in a `coordinator` home, before any batch fan-out, worktree allocation, or backend session exists.
`--secondmate` is exempt, because a persistent secondmate home is a separate mechanism with its own contract rather than a crew.
That refusal is a misconfiguration backstop and deliberate friction, not a security boundary: anything running as this Linux account can edit `config/role`, drive a backend directly, or start an agent by hand, so the account is the real boundary.
It is the same honesty [`subagent-guard.md`](subagent-guard.md) states about its own scope, and it must not be described to anyone as a guarantee.
The shipped primary-session delegation guard already denies delegation-shaped tools in every primary home regardless of role, so no coordinator-specific extension of it is needed.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer, `tasks-axi update --help` exposes `--archive-body`, and `tasks-axi mv --help` exposes `[<id>...]` for the atomic multi-ID move introduced in 0.2.2 and required by handoff delegation.
That sentence is the single owner of the tasks-axi compatibility definition; every other document points here instead of restating the version gates.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.
At session start, `bin/fm-backlog-lint.sh` read-only checks current `blocked-by:` edges for missing targets, already-Done targets, and the archived-target disagreement between `tasks-axi` and `bin/fm-fleet-snapshot.sh`.
It is silent when clean, never blocks or mutates records, and is also available as a standalone command.
Session-start cost stays bounded regardless of how much rot the backlog carries: a clean backlog runs no `tasks-axi` process at all, and any number of stale edges is resolved against one `tasks-axi list` call.
It runs in both backend modes; the fix clause prescribes `tasks-axi unblock` only where that command would actually run, and otherwise names the backlog file, the record, the blocker id, and the `blocked-by:` token quoted as that record actually spells it - under `manual`, and on any record `tasks-axi` cannot resolve, where it also says no automated fix is available.
The classification boundary is what the readers could decide: dangling and already-Done edges are decided from the parsed backlog and archive alone and stay `BACKLOG_STALE` findings even for an unresolvable record, while the reader-disagreement class needs `tasks-axi`'s own answer, so an unresolvable record reports the coded `BACKLOG_UNREADABLE` bootstrap diagnostic naming the record and the row repair that closes it, reports no stale edge for that class, and exits 1 to mark the run undecided without blocking session start.
The full fleet and bearings snapshots use the same dangling classification to surface ready work with a data-integrity caution instead of treating a target found nowhere as a live blocker; `fm-fleet-snapshot.sh --backlog-json` stays raw per-file input so lint can still compare reader behavior.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag firstmate passes when it spawns a task, then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-auto-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses a deeper `fm_backend_agent_alive` probe where verified.
Today that probe can classify tmux and herdr secondmate endpoints as `alive`, `dead`, or `unknown`; zellij, Orca, and cmux report `unknown` until their own agent-process classifiers are verified.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and uses the same recorded backend target fields after loading `state/<id>.meta`.
By default, Herdr workspaces are derived from `FM_HOME`: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
The default-container spawn, list-live, and recovery paths read that label from the active home, so a secondmate's own crewmates stay inside that secondmate home's herdr space.
The optional local `config/herdr-presentation-spaces` presence flag instead enables Herdr's default-off disposable single-task visual projection; [`docs/herdr-backend.md`](herdr-backend.md#optional-disposable-single-task-presentation-spaces) owns its behavior, safety limits, and recovery contract.
The flag is default-off and inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path described in [`docs/cmux-backend.md`](cmux-backend.md)'s "Test safety" section, never enumerate-and-close every workspace.
The `config/backend` file is not inherited by secondmate homes.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the channel reference and macOS verification evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
That evidence policy is specific to the firstmate repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but firstmate keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md), and [herdr-backend.md](herdr-backend.md) owns the real-Herdr lane's verification and isolation rationale.

## Codex profile and Graphify hooks (.codex/)

The tracked `.codex/config.toml` is the authoritative Codex Firstmate profile for firstmate-spawned Codex agents.
A Codex crewmate works in some other project's worktree, which has no such file, so `bin/fm-spawn.sh` parses this repo's copy and passes its `sandbox_mode`, `approval_policy`, and `approvals_reviewer` values as repeatable `codex -c key=value` overrides whenever it launches a Codex crewmate or secondmate.
Those overrides currently set `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, and `approvals_reviewer = "auto_review"` so Codex keeps a workspace sandbox and uses auto review for approval decisions.

Do not treat that file as inert for sessions running inside this repository.
Codex 0.145.0 reads it as configuration for a Codex session whose working directory is in this repo, which is measured in [`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 5 and corrects an earlier claim here that repo-local `.codex/config.toml` is never auto-loaded.
Anything written into it therefore reaches a supervising Codex firstmate session too, not only the crewmates `fm-spawn` launches.

For that reason one Codex sandbox setting deliberately does NOT live in that file.
A Codex CREWMATE additionally receives `sandbox_workspace_write.network_access=true` on its launch line, which is what lets it reach the local no-mistakes daemon socket; a Codex secondmate does not receive it, and neither does the supervising session.
Codex classes a unix-socket connect as network access rather than filesystem access, and 0.145.0 offers no narrower knob, so this is a whole-dimension grant that also admits general outbound network from that crewmate.
[`docs/codex-sandbox-network.md`](codex-sandbox-network.md) owns the measurements behind all of that, including what the grant admits and why the launch line rather than the profile file is the only placement that confines it.

The tracked `.codex/hooks.json` has `SessionStart`, `PreToolUse`, and `Stop` project hooks.
Its `SessionStart` hook is the Codex integration for `bin/fm-sessionstart-nudge.sh`; see [`docs/sessionstart-nudge.md`](sessionstart-nudge.md) for the full native session-start nudge contract.
Its `Stop` hook is the Codex integration for `bin/fm-turnend-guard.sh`; see [`docs/turnend-guard.md`](turnend-guard.md) for the full primary turn-end supervision contract.
Its `PreToolUse` hooks run the supervision-arm, cd-guard, and lavish-guard seatbelts plus a fail-open Graphify check.
The Graphify hook exits successfully if `graphify` is not on `PATH`; otherwise it runs `graphify hook-check` with a ten-second timeout.
That hook is intentionally portable and bounded so Codex tool use is not blocked by a missing Graphify install or a slow hook.

`graphify-out/` is local, generated Graphify state and stays gitignored.
Dirty files under `graphify-out/` are expected after hooks or incremental updates and are not a reason to skip Graphify-assisted navigation when `graphify-out/graph.json` exists.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.
There is no shared learnings file by captain decision.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
`fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh firstmate worktree for the secondmate home.
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This marker rule relaxes protection for nothing else; the separately narrow checkout-local runtime artifacts are covered in "Operational home layout and state" above.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, `projects/`, and the `.local/axi/` npm prefix come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Every task `bin/fm-spawn.sh` launches is told its home explicitly: a crewmate or scout inherits the launching process's own `FM_HOME`, and a `--secondmate` spawn is given the secondmate's own home, so the worker's `fm-send.sh` targets, findings surface, and state resolve against the home that launched it rather than falling back to a repo root or to whatever an operator shell profile defaults to when `FM_HOME` is unset.
That home reaches the agent through the launch command on every backend, and on tmux it is additionally seeded into the task window before its shell starts, which is the only backend offering that seam; [`docs/tmux-backend.md`](tmux-backend.md) owns the measurement, the tmux 3.0 floor it needs, and the limit on the other backends.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Watcher service

`bin/fm-watcher-service.sh` selects a `systemd --user` template when the user manager is usable and otherwise selects a detached tmux keeper whose recognizable basename prefix is paired with a truncated SHA-256 digest of the complete home path.
The collision-resistant digest is the keeper's identity; a one-time migration stops the former checksum-named session only after this home's pid and lock records prove ownership, so upgrades neither orphan a keeper nor touch another home's colliding legacy name.
The tracked template is `systemd/fm-watch@.service`.
The instance is `fm-watch@$(systemd-escape --path "$FM_HOME").service`, so each operational home has an independent restart boundary.
The first unit copy and `enable --now` require explicit captain consent through `WATCHER_UNIT:` and `bin/fm-bootstrap.sh install watcher-unit`.
Bootstrap never installs or enables the unit silently.
After installation, every locked bootstrap compares the tracked template bytes, the checkout path, a hash of the watcher entry point plus its in-memory shell libraries and backend adapters, the running manager identity, and the X-mode environment hash, then reloads and restarts only a stale instance.
That convergence restarts a unit whose old process survived a `/updatefirstmate` fast-forward and would otherwise keep executing old watcher bytes.
`config/x-mode.env` is an optional second `EnvironmentFile` on the template, while `state/.watch-service.env` records its hash so an opt-in, opt-out, or cadence change triggers convergence.

`state/.watch-service.env` also records the `PATH` the service runs with, composed by `bin/fm-service-path-lib.sh` from where this deployment actually keeps its tools.
Neither unit template sets a `PATH`, so without that line a unit inherits the `systemd --user` manager default, which reaches no tool installed outside the system directories.
That is not a loud failure: on 2026-08-04 this vessel's watcher could reach neither the `no-mistakes` CLI nor `gh`, so `bin/fm-crew-state.sh` answered `unknown` for every crew and the merge poll read every open pull request as unmerged, with no error anywhere.
The composed value is deterministic for a given installed tool set, so it does not churn between sessions, and `service_env_matches` compares it, so a home whose toolchain moves reconverges and restarts.
Locked bootstrap additionally reports `WATCHER_UNIT: the watcher's recorded PATH cannot reach ...` for a required tool that recorded value cannot reach.
That report has two forms, because the repair differs: a tool this session can resolve is fixed by converging the service from here, while a tool this session cannot resolve either means the recorded value was composed blind and no convergence from this session can improve it.
Getting an uninstalled tool installed stays owned by the toolchain check's `MISSING:` line; what the second form adds is that the service environment was recorded without the tool, which `MISSING:` does not say.
That pair is about one RECORDED service, and the same question about the seat as a whole - whether any context inheriting no shell setup reaches the run-state reader's own dependency - is the separate `RUN_READER:` line owned by [docs/run-reader-reach.md](run-reader-reach.md), so a repair on one side does not clear the other.
The tmux keeper fallback takes the same composed value as its sixth argument, because `tmux new-session` runs its command under the tmux server's environment rather than the launching session's.
Because an argument leaves no comparable trace, the keeper's watcher records it under `state/.watch.lock/service-path`, and convergence compares that record exactly as it compares the systemd tier's recorded environment, so a toolchain move restarts either tier.
The Bridge frequency-monitor unit records and compares the same `PATH` for the same reason, so its convergence below covers it too.
User lingering keeps a user service alive without an interactive login session.
If `loginctl` reports lingering disabled, bootstrap emits a separate `WATCHER_UNIT:` consent request for `bin/fm-bootstrap.sh install watcher-linger`; it never calls `loginctl enable-linger` without that approval.
When `systemctl --user` is unusable, the tmux keeper fallback starts automatically and needs no unit or linger installation.
Both tiers run `bin/fm-watch.sh` with `FM_WATCH_DAEMON=1`; the queue, delivery, guard, and harness contracts do not change with the selected keeper.

## Wake-delivery service

`bin/fm-delivery-service.sh` is the watcher service's companion and uses the same collision-resistant full-home keeper naming and ownership-proven legacy migration as the watcher: a `systemd --user` template when the user manager is usable, otherwise a detached tmux keeper.
The tracked template is `systemd/fm-delivery@.service` and the instance is `fm-delivery@$(systemd-escape --path "$FM_HOME").service`, so each home has an independent restart boundary for delivery as well as for detection.
The first unit copy and `enable --now` require explicit captain consent through `DELIVERY_UNIT:` and `bin/fm-bootstrap.sh install delivery-unit`.
Convergence, the recorded `PATH`, and the keeper tier's handed-down `PATH` argument all follow the watcher's rules above; `state/.delivery-service.env` is its environment file and `state/.delivery.lock/service-path` its keeper-tier record.
`docs/wake-delivery.md` owns what the listener does with that lifetime, including the verdicts `bin/fm-delivery-service.sh status` reports and why silence is never one of them.

## Bridge frequency monitor service

`bin/fm-frequency-monitor.sh` is a separate plain-shell Bridge inbox loop with a default five-second cadence.
It does not run an agent or tighten the main watcher's cadence.
The fast path reads only the first vessel resolved from `FM_BRIDGE_VESSEL` or `config/bridge-vessel`, so one home never becomes a fleet-wide scanner.
`bin/fm-bridge-inbox-lib.sh` is the single owner of Bridge tree signatures, priority reads, surfaced markers, and durable `fm_wake_append check bridge-inbox` publication for both this monitor and the original watcher.
Its separate inter-process lock serializes the signature comparison through marker publication, while `fm_wake_append` independently serializes wake sequence allocation and queue append.
A live delivery listener observes the non-empty queue immediately.
When no session is live, the same queue record remains durable until session start drains it, so the monitor needs no second pending-mail store or repeated agent wake.

The tracked template is `systemd/fm-frequency-monitor@.service`.
The instance is `fm-frequency-monitor@$(systemd-escape --path "$FM_HOME").service`, with private per-home values in `state/.frequency-monitor-service.env`.
Bootstrap considers the component only when the home has a non-empty Bridge vessel configuration.
The first unit copy and `enable --now` require explicit captain consent through `FREQUENCY_MONITOR_UNIT:` and `bin/fm-bootstrap.sh install frequency-monitor-unit`.
Bootstrap never installs, enables, or starts this new standing process silently.
After installation, locked bootstrap converges stale template bytes, checkout paths, loaded script versions, and service state.
The original 300-second Bridge check remains in `bin/fm-watch.sh` as a slower fallback and independent delivery backstop.
If `systemd --user` is unavailable, bootstrap reports that fast delivery is unavailable and does not invent or auto-start another standing process.
The watcher service's separately consented lingering setting applies to the same user manager.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The Codex 0.145.0 busy-row evidence behind its watcher liveness backstop lives in [`docs/codex-busy-detection.md`](codex-busy-detection.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Primary-session turn-end guard integrations for verified harnesses are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
The Codex repo-local profile and Graphify PreToolUse hook are documented above because they are Codex configuration, not harness launch mechanics.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude and Grok use background-notify delivery waits, Codex uses bounded foreground delivery checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.

## Direct Telegram receiver (config/telegram.env / config/fm-tg-recv.sh)

Direct Telegram receive is an optional per-home local integration.
Enable it by creating gitignored `config/telegram.env` and an executable gitignored `config/fm-tg-recv.sh` under the effective config directory.
The local receiver script owns Telegram credentials, polling, parsing, send behavior, and the exact `CAPTAIN-TELEGRAM` payload it prints.
The tracked `bin/fm-tg-recv-arm.sh` wrapper owns only the session-start arm shape: it starts one receiver for the effective `FM_HOME` or attaches to an already running matching receiver.
When a locked `bin/fm-session-start.sh` sees both files, its digest emits the separate tracked-background arm step for `bin/fm-tg-recv-arm.sh`; read-only sessions report that the lock holder owns arming.
When `config/telegram.env` is absent the feature stays silent except for the session-start inactive line.
When `config/telegram.env` exists but `config/fm-tg-recv.sh` is missing or not executable, session start reports that direct Telegram receive is not armed.
The wrapper records the receiver incarnation in `state/.tg-recv.lock` with the same portable lock discipline as watcher state and relays any captured receiver output once before cleaning a dead recorded receiver.
Run `bin/fm-tg-recv-arm.sh` as its own harness-tracked background task when the digest says active; never bundle it with another command, pipe it, redirect it, use shell `&`, or replace the session-start watcher protocol with it.

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Pi secondmate launches, `fm-spawn.sh` starts Pi with `-e` pointed only at the secondmate home's own tracked `.pi/extensions/fm-primary-turnend-guard.ts`, already present from the secondmate home's git worktree.
Wake delivery follows the external service contract in `docs/wake-delivery.md`.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves that rule directly or through a supported selector, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics; `AGENTS.md` section 4 keeps only the dispatch procedure and points here.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "select": "<optional strategy>",
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice and does not need a selector property.
`select: "quota-balanced"` remains accepted on rules for compatibility and has the same behavior as an implicit array choice.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array selection path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
Quota-aware selection is implemented by `bin/fm-dispatch-select.sh`, whose header owns provider and product mapping, relevant-window scoring, the stale-clear freshness margin, random tie-breaking, OS-backed random operational fallback, and safe selection-basis diagnostics.
Quota-data trouble never blocks dispatch, but malformed profile configuration remains an actionable validation error.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, an unknown `select`, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
Because the spawn backstop is gated by file presence, any fallback path after a missing match, validation error, or missing `jq` still passes a resolved harness explicitly until the file is fixed or removed.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Model panel roles (config/model-panel.json)

A model panel has two analysts answering one question independently on different models and a third model judging both reports.
The roles are pinned in `bin/fm-model-panel.sh`; the models filling them are configuration, because a model name in tracked code rots silently and a home can only run a panel on the models it can actually reach.
This section is the single owner of the panel's configuration schema, resolution order, and degradation contract; the script's header owns its commands and flags, and the [`panel` skill](../.agents/skills/panel/SKILL.md) owns when a panel is worth its cost.

`config/model-panel.json` is an optional local, gitignored file mapping each role to a dispatch profile.

```json
{
  "roles": {
    "analyst_a": { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" },
    "analyst_b": { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" },
    "judge": [
      { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
    ]
  }
}
```

A role's value is one profile object or a non-empty array of them, exactly the shape "Crew dispatch profiles" above defines, and every role resolves a concrete profile through `bin/fm-dispatch-select.sh`.
Panel profiles therefore get the same validation and the same quota-aware array selection as crew dispatch profiles through that shared implementation, with no separate panel selector.
`bin/fm-model-panel.sh`'s header owns the uniform validate-filter-select role-selection stages and the one-candidate invariant, while the selector's header owns quota and random-selection mechanics.
An omitted `model` or `effort` leaves that launch axis at the harness's own default, but a harness default is not treated as a model identity.
In a full panel, either analyst resolving to a profile without an explicit model pin refuses with exit 4 because Firstmate cannot prove that the analysts are different models.
An unpinned judge prints a warning and proceeds under the existing judge-sharing policy, and an unpinned seat in the reduced form prints the same class of uncertainty warning.
There is deliberately no injected effort default, because a profile carrying an effort its harness does not accept is rejected as an invalid pair.
Panels are ambiguous investigation work, so a high effort level is usually the right configured value - see [`docs/examples/model-panel.json`](examples/model-panel.json) for a starting point to copy.

Each role resolves in this order: its entry in `config/model-panel.json`, then the top-level `default` profile set in `config/crew-dispatch.json`.
That fallback is the documented default, and it is why a home that already declares which runtimes it dispatches on can run a panel with no panel-specific configuration at all.
When neither file supplies a profile for a role, the panel refuses and names both files rather than guessing a model.
A role backed by an array prefers a candidate with an explicit model pin that the panel is not already using, so the second analyst picks a known second model instead of either a duplicate or an unpinned default.

Configured model identity for that comparison exists only when the resolved profile explicitly pins a model, and it is that model name with any provider prefix and any `:suffix` removed - the normalization `bin/fm-dispatch-select.sh` already uses.
A profile without a model pin has unknown runtime model identity because its harness name identifies the launcher rather than the model chosen by that launcher's mutable default.
Two profiles naming the same model through different harnesses are therefore correctly one model, not two.
This guarantee covers normalized configured model names, not endpoint deployments or underlying weights, because different names can still alias something Firstmate cannot observe.
The panel never asks a running model to identify itself: self-report is not evidence of which endpoint or weights served the answer.
When weights-level independence matters, establish it before configuring the panel from provider-published identifiers or another non-self-report discriminator, and state plainly when that evidence is unavailable.

Degradation is explicit and never silent.
When either analyst has unknown model identity or both analysts resolve to the same configured identity, `start` refuses with exit 4 and names both the configuration fix and the reduced form; analysts whose independence cannot be established are not a panel, and presenting them as one is worse than running none.
The reduced form is opt-in through `--reduced` and is recorded and labelled everywhere as a single-analyst review rather than a panel, in the briefs, in the panel record, and in the judge's own report.
When no third distinct configured model is available, the judge may share an analyst's model, and an unpinned judge may do so unknowably; either case prints a warning and proceeds, because the judge's independence comes from re-verifying claims against live state with every report in hand.

`config/model-panel.json` is deliberately NOT in the inheritable set that `bin/fm-config-inherit-lib.sh` declares, for the same reason as `config/backend`: it names the models a specific home can actually reach, and pushing the primary's list into every secondmate would overwrite exactly the local knowledge that lets each home field a real panel.
A secondmate home that needs a different lineup writes its own file, and a home that writes none still inherits the primary's `config/crew-dispatch.json` default profile set through the normal inheritance path.

## Findings surface (config/findings-dir / FM_FINDINGS_DIR)

The political officer appends findings to one directory on the host and has no other way out.
`docs/findings-surface.md` owns what a finding means, what the drain rule is and why, and what a written-back outcome carries.
`bin/fm-finding-lib.sh` owns what a finding and an outcome are checked against, `bin/fm-finding.sh --help` owns the emit and read commands, and `bin/fm-finding-drain.sh --help` owns the drain and write-back commands.
This section owns only where the directory is.

Resolution order is `FM_FINDINGS_DIR`, then the single path on the first line of `config/findings-dir`, then `FM_HOME/data/findings`.
The pointer exists because the officer is one container per MACHINE while a home is one vessel: a machine carrying several vessels points every home at the one directory the officer appends to.
A `config/findings-dir` that exists but names nothing is refused with exit 2 rather than falling back, because a fallback would send findings to a directory nobody collects from and report success while doing it.

`config/findings-dir` names a path that is a property of the machine, not of the vessel, so it is NOT in the inheritable set that `bin/fm-config-inherit-lib.sh` declares - the same reason as `config/backend` and `config/model-panel.json`.
A secondmate home on the same machine as its primary writes the same pointer; one on a different machine must not inherit a path that machine does not have.

Nothing creates the surface implicitly: `fm-finding.sh init` creates it and says so, and every other command refuses an absent surface with exit 3.
A reachable surface always reports counted numbers and an unreachable one reports no number at all, so an empty surface and a surface nobody can reach are never the same reading.

## Event batching delays (config/batch-delays)

The event batcher groups supervision events by priority and holds each class for a bounded time.
`docs/event-batching.md` owns why it exists and what is proven, `bin/fm-event-batch-lib.sh`'s header owns the record formats and the classification rule, and `bin/fm-event-batch.sh --help` owns the commands.
This section owns only where the numbers come from.

The captain's own values are `immediate` with no delay at all, plus shipped defaults of 60 seconds for `high`, 120 seconds for `normal`, and 600 seconds for `low`.
`immediate` is not configurable because it is the class released by the admission that opens it; no delay at all is a property of that class rather than a default anyone sets.

`config/batch-delays` overrides the three configurable delays for one home.
The schema is one `name = seconds` per line, where `name` is one of `high`, `normal`, or `low` and `seconds` is a whole number; blank lines and `#` comments are ignored, and an unnamed class keeps its shipped default.

```text
# this home releases finished work sooner
high = 30
low = 300
```

Resolution order for each configurable class is the environment variable (`FM_BATCH_DELAY_HIGH`, `FM_BATCH_DELAY_NORMAL`, `FM_BATCH_DELAY_LOW`), then this file, then the shipped default.
`fm-event-batch.sh delays` reports the fixed zero hold for `immediate` and the resolved number for each configurable class together with its source.
A value that is not a whole number of seconds is refused with exit 2 rather than falling back, because a home that mistyped its delay would otherwise be handed the shipped default while believing it had configured one.
An empty value is present and malformed rather than absent, whether it comes from the file or the environment.
An `immediate` entry, in this file or as `FM_BATCH_DELAY_IMMEDIATE`, is refused with exit 2 for the same reason: that class is never held, so a value set for it could only ever be inert, and accepting one silently is the same defect as accepting a mistyped one.
Presence alone triggers the `immediate` refusal, including an empty value.

`config/batch-delays` is not in the inheritable set that `bin/fm-config-inherit-lib.sh` declares, for the same reason `config/bosun-judge` is not: nothing reads a batch yet, so whether a secondmate home should inherit these numbers belongs to whichever unit first points a consumer at them.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi, compatible tasks-axi per "Backlog backend" above, and quota-axi.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
Graphify is optional: Codex's PreToolUse hook fails open when `graphify` is absent, so bootstrap does not report it as a required install.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi` with an install command targeting `$FM_HOME/.local/axi`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent `quota-axi` reports `MISSING: quota-axi` with the same home-owned prefix; `bin/fm-dispatch-select.sh` still selects uniformly from the valid candidate array with an OS-backed random source when quota data is unavailable.

### AXI-suite self-update

Locked bootstrap runs `bin/fm-axi-suite.sh` at most once per `FM_AXI_SUITE_CHECK_INTERVAL` for the configured AXI commands.
Each vessel derives its npm prefix as `$FM_HOME/.local/axi` without configuration, so different operational homes never share the updater's write destination.
Firstmate entrypoints put `$FM_HOME/.local/axi/bin` first on `PATH`, and `bin/fm-spawn.sh` exports the owning vessel's bin first for every crewmate while a secondmate launch receives the secondmate home's bin first.
The recommended primary launch commands also prepend that directory before the harness starts, so a bare AXI command resolves the vessel copy whenever it exists and uses an inherited external installation only as the pre-cutover fallback.
On the first normal currency check, an existing external AXI installation is left untouched and its installed version is re-installed into the vessel prefix, or an eligible patch/minor release is installed there directly.
No existing installation is moved or removed.
Patch and minor releases update automatically in the vessel prefix, while major releases and newly required commands emit `AXI_SUITE_REVIEW:` for captain approval.
When a major release is pending and the vessel copy is absent, the updater seeds the currently installed major into the vessel prefix without accepting the major upgrade.
A vessel copy that answers without reporting a version would shadow the intact external copy for every consumer of that home's `PATH`, so the updater removes it and reseeds from a readable version instead of trusting it; the same removal happens when an install leaves a copy that cannot be read back.
A copy that never answers is reported and left alone instead, because a bounded probe cannot distinguish a hung binary from a very slow working one.
A locally-ahead build that the registry cannot supply is reported as `AXI_SUITE_REVIEW:` rather than a failure, because the external copy remains the working fallback until that build is published or the vessel accepts the registry version.
Successful changes emit `AXI_SUITE_UPDATED:`, and bounded registry, permission, install, verification, or hook failures emit `AXI_SUITE_STUCK:` and persist under `state/` until a successful check clears them.

The check also reports, separately, whether the maintained copy is the copy that actually runs.
Every firstmate entrypoint prepends the vessel bin directory into its own process, and the updater does the same before measuring, so until 2026-08-04 the currency report described the copy the vessel maintains and never asked whether anything else resolves it.
Hand measurement on the coditan vessel that day found a firstmate-home shell resolving all six suite tools from `~/.npm-global/bin`, every one behind the maintained copy, while the check reported the suite current.
The version gap is not the defect; a true all-clear about a copy nobody runs is, and it is the same shape as a watcher reading crew state through a `PATH` that cannot reach the tool it needs.
`bin/fm-axi-path-lib.sh`'s `fm_axi_shadowed` therefore answers that question against the environment the SESSION had, and each mismatch emits `AXI_SUITE_SHADOWED:` naming both paths.
Capturing the updater's own PATH before its own prepend is not enough, because the session entrypoint and bootstrap both prepend and export before the check is ever spawned, so `fm_axi_prepend_path` records the PATH it replaced the first time any entrypoint runs and no later prepend overwrites that record.
That record carries the pid that made it and is honoured only for that process and its descendants, because an exported value nothing overwrites has the lifetime of a process tree rather than of the session it describes: `tmux new-session` freezes the launching environment into a new server, and every pane opened there afterwards inherits the snapshot.
A record from another tree is re-taken when this process's own `PATH` does not already lead with the maintained prefix, and otherwise the check reports `AXI_SUITE_SHADOW_UNKNOWN:` rather than answering about a session that may be gone.
A tool this home maintains no copy of is not reported, because an unseeded vessel resolving every tool externally is the ordinary pre-cutover state that the seeding and currency paths already own.
That report is outside the cadence gate and is never cached, because it describes the caller's environment rather than the registry and that environment changes between sessions while a cadence stamp does not.
Firstmate-launched processes are made to resolve the maintained copies rather than merely reported on: the entrypoints and `bin/fm-spawn.sh` already prepend the vessel bin directory, and both background-service environments now compose their recorded `PATH` with it prepended.
An inherited login environment is not firstmate's to change, so a shadowed tool there is reported for the captain to resolve and never silenced by editing his shell configuration; the older copy is likewise never deleted, because in an environment without the maintained directory that makes the tool unrunnable rather than current.
What that leaves the captain is a per-launch `PATH` prefix he has to remember every time, so `bin/fm-axi-path-lib.sh` is sourceable on its own to make the same repair available once: with neither an argument nor `FM_HOME` it falls back to its own checkout, the same `${FM_HOME:-$FM_ROOT}` fallback every other script applies, which lets a login profile source it and name the checkout exactly once (README.md "Install and launch").
That changes nothing about the position above, because firstmate still neither writes nor reads any shell configuration: sourcing it is the operator's own choice in his own file, and a home that never makes that choice behaves exactly as before and keeps being reported rather than repaired.
A shell that cannot locate the sourced file leaves the fallback empty and prepends nothing, because a guessed directory on `PATH` is the confident wrong answer the shadow reporting exists to prevent.
The documented profile route prepends the directory printed by `fm_axi_bin_dir` and deliberately does not call `fm_axi_prepend_path`, because the ambient record belongs to firstmate's own entrypoints: a login shell that claimed it would record its pre-prepend `PATH`, and since every session started from that shell is its descendant, the check would honour that record and report the maintained copies as shadowed while the captain's shells were in fact running them.
Verified by effect on 2026-08-04 with a control: with `fm_axi_prepend_path` in the profile the login ran the maintained copy and the check still printed `AXI_SUITE_SHADOWED:` naming the stale path, and with the documented form the same login ran the maintained copy and the check printed no shadow line at all.
Neither the ambient claim nor `fm_axi_shadowed` was changed for this; teaching them to attribute operator-level prepends is a separate question from making the repair available.
The cadence stamp remains under that vessel's `state/`, and `state/axi-suite-prefix-v1.cutover` records that this home already attempted the isolated seeding, so a stamp written before the cutover cannot postpone it.
The marker records the attempt and not its outcome: a home that could not seed every tool retries on the next cadence window instead of paying a full registry sweep, and a repeated alarm, on every session.

Hook setup for `gh-axi`, `chrome-devtools-axi`, and `lavish-axi` is the one part of the suite that the prefix cannot isolate: `<tool> setup hooks` writes the user-global harness surfaces (`~/.claude/settings.json`, `~/.codex/`, `~/.config/opencode/plugins/`) that every vessel on the host shares.
The updater and the printed install commands therefore invoke the tool by name with the vessel bin directory first on `PATH`, so the installer records the portable command name rather than one home's private path and every vessel converges on identical content.
Removing a vessel home cannot break another home's hook wiring as a result, but the wiring itself stays shared: the last vessel to run hook setup owns the version of that shared config on disk.
`FM_AXI_SUITE_NETWORK_TIMEOUT` bounds the suite's steady-state registry, update, and hook work, `FM_AXI_SUITE_PROBE_TIMEOUT` separately bounds its cumulative local version probing so a hung suite binary cannot wedge session start, `FM_AXI_SUITE_SEED_TIMEOUT` separately bounds the one-time installs that give a fresh vessel its own copies, and `FM_AXI_SUITE_DISABLE` is reserved for tests or emergency diagnosis.
Each budget is charged only for the time its own calls spend, so no kind of work can exhaust another's: a first cutover installs the whole suite at once and would otherwise consume the tight steady-state network budget and report a healthy vessel as stuck.
An install that creates the vessel's copy is charged to the seeding budget and an install that replaces an existing vessel copy is an ordinary update, so the distinction never depends on which code path reached it.
Because seeding is much slower than a steady-state check, it reports on standard error which tool is installing and how much of the seeding budget remains, then closes with how many installs it attempted and how much of the budget it used.
That output streams live when a captain runs `bin/fm-bootstrap.sh` in a terminal; `bin/fm-session-start.sh` captures bootstrap output for the digest, so under automated session start the same lines arrive together once bootstrap returns, and the summary is what makes the pass interpretable after the fact.
A seed that genuinely stalls, or that is never attempted because the seeding budget is already spent, is still reported as `AXI_SUITE_STUCK:` naming which of the two happened, identically from both install paths; the external copy remains the fallback and the next cadence window retries.

### Upstream firstmate and curated-fork checks

`bin/fm-firstmate-update-check.sh` compares the local default branch with the configured comparison base and persists a signal only when an upstream-only commit changes `AGENTS.md`, `bin/`, `roles/`, or `.agents/skills/`.
`bin/fm-fork-sync-check.sh` compares the curated fork with real upstream, self-gates successful checks to a three-day cadence, and points fork-only review at `docs/fork-patches.md`.
Neither script mutates the checkout or runs from bootstrap, so schedule them externally; their headers and `--help` output own exact overrides and mechanics.

Each check reads its own comparison base because the two answer different questions, and a curator vessel running from a fleet repository needs all of them at once.
The local gitignored `config/firstmate-update-base` names the artifact this deployment actually updates from, so the instruction-surface check compares against the right source instead of assuming the original template.
The local gitignored `config/fork-sync-upstream` names the real upstream the curated fork tracks, so the fork check keeps asking whether the fork absorbed upstream content even when the deployment itself runs from somewhere else.
The local gitignored `config/fork-sync-fork` names the curated fork itself, which is the other side of that same comparison.
Each file holds exactly one non-empty line naming a git URL (`https://`, `http://`, `ssh://`, `git://`, `git+ssh://`, or `file://`), an scp-style `host:path` remote, or an absolute local path; a relative path is refused because it would resolve against each caller's working directory.
Precedence for the two upstream bases, highest first, is the explicit `FM_FIRSTMATE_UPSTREAM_URL` environment variable, then the config file, then the default `https://github.com/kunchenguid/firstmate.git`.
The environment variable is passed through unvalidated so existing harnesses keep working, and it overrides both checks at once.
Precedence for the fork side, highest first, is `FM_FIRSTMATE_FORK_URL`, then `config/fork-sync-fork`, then a remote named `fork`, then `origin`; there is no default, because a fork nobody named cannot be guessed and the resolver refuses rather than inventing one.
Until 2026-08-17 the fork side came from `origin` alone, which is the fork only in the plain topology: on this curator vessel, deployed from a fleet repository, `origin` is that fleet repository, so the check compared upstream against it and listed its commits as fork-only patches while reporting a confident count.
The `fork` remote hop exists so such a seat measures correctly with no new configuration, because a remote spelled `fork` is an operator declaring in git's own vocabulary that this checkout's fork is a different repository from its origin; `config/fork-sync-fork` remains the way to state it rather than infer it, and is the hop to set wherever the inference is not obviously right.
Every `FORK_SYNC:` finding names both repositories it compared and which hop each came from, because a comparison that does not say what it compared cannot be caught reading the wrong thing.
Before fetching, the check establishes each side's repository identity rather than comparing URL spelling: GitHub repositories use the forge's numeric repository ID, while local and `file://` repositories use their symlink-resolved absolute git directory.
A fork side with the same established identity as upstream is refused as `FORK_SYNC_STUCK:` rather than compared, since comparing a repository with itself reports everything absorbed, which is the quietest possible wrong answer.
If either identity cannot be established, the check refuses as `FORK_SYNC_STUCK:` rather than guessing from URL spelling or proceeding with an unverified comparison.
A config path that exists but is not a readable regular file, such as a directory or a dangling symlink, is refused for that reason rather than treated as absent.
An absent file changes nothing for an unconfigured home, but a present unusable file never silently falls back: bootstrap reports it at startup as `CURRENCY_BASE:`, and the affected check records its own `FIRSTMATE_UPDATE_STUCK:` or `FORK_SYNC_STUCK:` rather than comparing against the wrong base.
`bin/fm-currency-base-lib.sh` is the single owner of that resolution and validation.
`config/firstmate-update-base` is inherited by secondmate homes since every home in a deployment updates from the same source; `config/fork-sync-upstream` and `config/fork-sync-fork` are not, because only the curator vessel curates the fork.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
When `FM_ROOT` sits on its default branch instead, bootstrap reports a `SELF_DRIFT:` line if that branch and its own origin disagree; [architecture.md](architecture.md#self-updates-stay-safe) owns the detection and remediation, and `FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT` below bounds its fetch.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inherited local material into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, `roles/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a live secondmate endpoint is skipped or respawn fails; already-live and successfully respawned endpoints are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `herdr-presentation-spaces`, `firstmate-update-base`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
The locked bootstrap inheritance pass uses the same per-home changed-set and reread path for already-running homes; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

### Daily currency round

`bin/fm-currency-round.sh` is the trigger behind firstmate's standing duty to check for updates daily, and the only thing that gives the two checks above a cadence that survives session boundaries.
Session start is not daily and neither check ran from bootstrap, so before this round a home that never installed an external timer never checked at all, and printed the same nothing a current home prints.
[currency-round.md](currency-round.md) owns the evidence, the hop vocabulary, the rejected alternatives, and the scope boundary; the script's header owns its flags, state files, and mechanics.

The locked bootstrap step arms the round with `--arm`, which writes and registers this home's `state/currency-round.check.sh` watcher check and is idempotent, so arming converges on every session start instead of depending on a per-home install step nobody verifies.
A failed arm reports `CURRENCY_ROUND:` rather than leaving the home quietly unwatched.
The watcher then runs the round on its ordinary `state/*.check.sh` sweep, and the round self-gates to its cadence so all but one sweep a day is a single file read.

Every session start also runs `--armed`, one file read and one comparison, which reports `CURRENCY_ROUND:` when this home is unarmed, has been armed without ever completing a round, or has stopped completing them.
That reading exists because a broadcast cannot reach a seat that has stopped listening, and a seat that stopped listening is the one most likely to be behind.

Each reading names the hop it speaks for - `released`, `pinned`, or `installed` - and the round measures the released and installed hops for this seat only.
It never updates anything, never acts on or measures another vessel, and never reports an all-clear for a reading it could not take.
`FM_CURRENCY_ROUND_DISABLE=1` silences only the reporting modes, for suites that compose `bin/fm-bootstrap.sh`.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which sets `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the X-mode cadence contract: an X instance polls every 30 seconds instead of the default 300, and only an X instance speeds up because a non-X home has no `config/x-mode.env`.
The watcher service template loads `config/x-mode.env` as an optional `EnvironmentFile`.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, the locked bootstrap convergence check compares the X-mode environment hash and restarts an already-installed stale service instance after opt-in, opt-out, or cadence change.
The tmux keeper receives the same environment when it respawns the watcher.
Away mode does not change this cadence because the external watcher keeps running while the away daemon consumes its queued events.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
X mode remains additive to non-X lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the X poll.
Its request handling remains in X-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, always finishing with a `--final` one when the task reaches a terminal state.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Bridge inbox check (FM_BRIDGE_*)

`bin/fm-watch.sh` and the optional fast frequency monitor read `inbox/<vessel>/new/` from a Bridge clone's fetched `origin/main`, turning pending envelopes into durable `check:` wakes without acknowledging or otherwise mutating them.
`FM_BRIDGE_VESSEL` selects one or more space-separated vessels, each watched independently, and falls through to local `config/bridge-vessel`; when neither is set the feature is silent and disabled.
A pre-existing single-vessel value keeps working unchanged: it is simply a one-element list.
`FM_BRIDGE_ROOT` selects the shared clone all listed vessels read from, while `FM_BRIDGE_URGENT_CHECK_INTERVAL` tightens the shared fetch-and-check cadence whenever any one vessel's highest declared pending priority is high or immediate.
Urgency promotion changes the priority delivered in the wake without changing this declared-priority cadence; `docs/urgency-promotion.md` owns that boundary.
The watcher caches each vessel's fetched tree signature and derived priority separately and surfaces each vessel's unchanged pending tree once, so one vessel's wake never suppresses or is suppressed by another's; fetches and reads are bounded with `FM_CHECK_TIMEOUT`.
The frequency monitor deliberately narrows that compatibility list to its first vessel and fetches it every `FM_FREQUENCY_MONITOR_INTERVAL` seconds.
Both paths share the same signature and marker implementation, so the slow fallback and fast service cannot drift in their definition of new mail or duplicate one signature during a concurrent check.

## Certsync health check (FM_CERTSYNC_*)

`bin/fm-watch.sh` folds certsync health into the ordinary heartbeat path when a certsync deployment is present under the home.
The default deployment path is `$FM_HOME/projects/hlr-certsync` with `docker-compose.yml`; `FM_CERTSYNC_PROJECT` and `FM_CERTSYNC_COMPOSE_FILE` override the project directory and compose file that mark certsync as deployed on this host.
The check reads certsync's status directly off the host filesystem.
It needs no docker socket, no `docker compose exec`, and no `docker`-group membership.
certsync exposes its heartbeat JSON and sqlite state DB under a readable host bind mount; see the certsync repo's `docs/deploy.md`, "State host path".
The watcher runs certsync's own `build_status` against those two files via `python3` with `PYTHONPATH=$FM_CERTSYNC_SRC` (default `$FM_CERTSYNC_PROJECT/src`), passing `FM_CERTSYNC_STATE_DB`, `FM_CERTSYNC_HEARTBEAT_FILE`, and `FM_CERTSYNC_DAEMON_STATE` as the `--state-db`, `--heartbeat-file`, and `--daemon-state` inputs.
Because `build_status` computes `healthy`/`reason` purely from those two files plus the daemon-state argument, this reproduces exactly the JSON the former `docker compose exec certsync certsync status` produced, with no docker access at all.
A confirmed JSON object with `healthy: false` becomes a durable `check` wake keyed as `certsync-health`, with the `reason` field trimmed and bounded in the wake text.
A `healthy: true` reading clears the unchanged marker and stays quiet when the heartbeat is fresh.
Because the files are read off the host rather than through a container `exec`, a stopped container or a daemon whose syncs have been failing no longer fails the read the way `exec` did; instead its heartbeat goes stale.
To keep "cannot confirm well" from collapsing into "is well", a `healthy: true` reading whose heartbeat file is older than `FM_CERTSYNC_HEARTBEAT_MAX_AGE` is reported as `unhealthy: heartbeat stale (...)` rather than staying quiet.
The daemon rewrites the heartbeat on every successful sync pass, at most 3600s apart, so the 7200s default has margin.
Set `FM_CERTSYNC_HEARTBEAT_MAX_AGE=0` to restore the raw `build_status` verdict with no freshness gate.
Missing `python3` or `jq`, an unreadable certsync source tree (`$FM_CERTSYNC_SRC/hlr_certsync/status.py` absent), a failed status computation, empty output, invalid JSON, and a missing boolean `healthy` field all produce their own `check` wake carrying a `cannot run: ...` reason, so an inability to read certsync's status can never read the same as a confirmed-healthy status; only a missing project directory or missing compose file (certsync not deployed on this host at all) stays quiet.
The command is bounded by `FM_CERTSYNC_HEALTH_TIMEOUT` rather than the general check timeout, and an unchanged unhealthy or unchanged cannot-run reading re-surfaces only after `FM_CERTSYNC_HEALTH_RESURFACE`.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for the Linux process-identity read in fm-wake-lib.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
FM_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
FM_BACKEND_HERDR_BARE_PROMPT_RE='^[❯›]'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. claude's ❯ or codex's ›; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text (dim or dark-truecolor) after an agent prompt reads empty via the shared fm_composer_strip_ghost (docs/herdr-backend.md "Incident (2026-07-08)", "Incident (2026-07-10)")
FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # herdr-only: maximum rows admitted between Pi's native-identity-corroborated separator pair; taller or ambiguous candidates stay unknown (docs/herdr-backend.md "Incident (2026-07-14)")
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Native agent-state submit confirmation")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
FM_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
FM_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
FM_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_FINDINGS_DIR=        # political officer's findings surface; overrides config/findings-dir, which overrides FM_HOME/data/findings
FM_FINDING_NOW=         # ISO-8601 UTC instant the drain rule computes deadlines against; unset means now. An unparseable value is refused, never replaced by the wall clock
FM_SERVICE_PORT_RANGE=4400-4499   # port window bin/fm-service-port.sh probes; above lavish-axi's 4387 default and below the ephemeral range
FM_SERVICE_PORT_PROBE_TIMEOUT=4000   # milliseconds allowed per readiness probe in bin/fm-service-port-probe.mjs http
FM_LAVISH_ALLOW_SHARE=0   # 1 permits `fm-lavish.sh share`, which publishes a review board to third-party hosting (docs/lavish-access.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or X-mode dispatch)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CERTSYNC_PROJECT=$FM_HOME/projects/hlr-certsync   # certsync deployment directory; presence of its compose file marks certsync as deployed on this host
FM_CERTSYNC_COMPOSE_FILE=$FM_CERTSYNC_PROJECT/docker-compose.yml   # compose file whose presence marks certsync as deployed (not exec'd; the check reads state off the host)
FM_CERTSYNC_SRC=$FM_CERTSYNC_PROJECT/src   # certsync source tree put on PYTHONPATH to run build_status on the host without docker or an install
FM_CERTSYNC_STATE_DB=/var/lib/hlr-certsync/certsync-state.sqlite3   # host path to certsync's state DB, read as build_status --state-db
FM_CERTSYNC_HEARTBEAT_FILE=/var/lib/hlr-certsync/certsync-heartbeat.json   # host path to certsync's heartbeat, read as build_status --heartbeat-file
FM_CERTSYNC_DAEMON_STATE=running   # build_status --daemon-state argument
FM_CERTSYNC_HEALTH_TIMEOUT=5   # seconds allowed for the heartbeat's certsync status read
FM_CERTSYNC_HEALTH_RESURFACE=3600   # seconds before an unchanged unhealthy or cannot-run certsync status is queued again
FM_CERTSYNC_HEARTBEAT_MAX_AGE=7200   # a healthy reading whose heartbeat is older than this reads as unhealthy (daemon stopped / syncs failing); 2x the 3600s max sync interval; 0 disables the freshness gate
FM_CONTEXT_CEILING=300000   # captain-decided token ceiling for the primary session's own context; above it, at a quiet boundary, the watcher queues a reset, ask, or blocked wake; unmeasurable running sessions surface as unenforced (docs/context-reset.md)
FM_CONTEXT_CAPTAIN_IDLE_SECS=1800   # silence since the last genuine captain prompt below which the captain counts as in live conversation: the watcher asks instead of ordering a reset, and bin/fm-context-reset.sh refuses; not applied on that tool's --captain-approved path, where an explicit approval replaces the inference (docs/context-reset.md)
FM_CONTEXT_RECEIPT_MAX_AGE=900   # seconds a state/.stow-receipt stays fresh; the receipt and the reset are meant to happen in one turn; not applied on bin/fm-context-reset.sh's --captain-approved path, which requires instead that the receipt was filed after the approval
FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES=262144   # bytes the transcript may advance past the position the receipt was bound to before that receipt no longer describes what a reset would discard
FM_CONTEXT_TAIL_BYTES=2097152   # bounded trailing transcript read per measurement, widened once to the whole file when that tail holds no captain record
FM_CONTEXT_CHECK_INTERVAL=300   # seconds between the watcher's context-ceiling reads
FM_CONTEXT_ERROR_RESURFACE=3600   # seconds an unchanged context-ceiling report stays quiet before it is made again; a changed branch class is never held
FM_BRIDGE_VESSEL=         # optional override for config/bridge-vessel; one or more space-separated vessels; absent disables Bridge inbox scanning
FM_BRIDGE_ROOT=$FM_HOME/projects/coditan-bridge   # Bridge clone whose origin/main ref the watcher reads
FM_BRIDGE_URGENT_CHECK_INTERVAL=30   # Bridge-only cadence while highest declared pending priority is high or immediate
FM_FREQUENCY_MONITOR_INTERVAL=5   # seconds between plain-shell Bridge fetch/check cycles in the optional fast service
FM_FREQUENCY_MONITOR_CONFIRM_TIMEOUT=10   # seconds fm-frequency-monitor-service waits to confirm a fresh unit before reporting failure
FM_WAKE_ECHO_BYTES=8192   # total bytes of drained queue records one bin/fm-wake-drain.sh may echo into a wake turn; anything past it is withheld from the echo, never discarded, and the drained file is preserved under state/.wake-drain-overflow.<epoch>.<pid> with the path printed; a non-numeric or zero value falls back to 8192 (docs/supervision-cost.md "Repair 2")
FM_WAKE_ECHO_ROW_BYTES=1024   # per-record byte cap under FM_WAKE_ECHO_BYTES, so one pathological payload cannot consume the whole budget and hide every other record behind it; a shortened row is marked and its full text is in the preserved file; a non-numeric or zero value falls back to 1024
FM_TRANSCRIPTS=~/.claude/projects   # provider transcript root bin/fm-supervision-cost.sh measures; read-only, and the only harness that keeps such a record is Claude Code (docs/supervision-cost.md)
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
NO_MISTAKES_INSTALL_DIR=~/.no-mistakes/bin   # the no-mistakes INSTALLER's own variable, not firstmate's; bin/fm-nm-path-lib.sh reads it to resolve the CLI for contexts that inherit no shell setup, and firstmate adds no second name for the same location (docs/run-reader-reach.md)
FM_RUN_READER_CHECK_DISABLE=0   # test-only: silence bootstrap's RUN_READER assertion, because every fixture's fake CLI is unreachable by construction; tests/lib.sh sets it and tests/fm-run-reader-reach.test.sh sets it back
FM_PDF_GS=gs            # Ghostscript binary bin/fm-pdf-finish.sh and bin/fm-pdf-verify.sh drive as PDF producer and reader; absent means both refuse with exit 3 (docs/pdf-output.md)
FM_GRADE_DB=~/.no-mistakes/state.sqlite   # no-mistakes run database bin/fm-grade.sh reads for the review-quality scale; opened read-only and never written (docs/review-grading.md)
FM_GRADE_CORPUS=bin/fm-grade-corpus   # sealed defect corpus directory bin/fm-grade.sh scores blind replay against (docs/review-grading.md)
FM_GRADE_REPO_<NAME>=   # clone path for one corpus case's `repo`, name uppercased with non-alphanumerics as underscores; tried before $FM_HOME/projects/<repo> (bin/fm-grade-corpus/README.md)
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting X-mode completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on X-mode completion follow-ups per linked mention
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_LOCK_STEAL_MAX_DEPTH=8   # hard cap on nested stale-lock steal recursion; acquisition fails loudly (rc 2) past this depth instead of recursing unbounded
FM_LOCK_WAIT_TIMEOUT=30   # seconds a blocking lock acquisition may remain contended before it fails loudly (rc 2)
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_DELIVERY_POLL=2      # seconds between wake-delivery listener cycles in bin/fm-delivery.sh; each cycle touches the beacon, reads the durable queue, and submits when one is due (docs/wake-delivery.md)
FM_DELIVERY_RETRY=45    # seconds before the listener resubmits while the same wakes are still pending; a submitted wake becomes a model turn that has to RUN before it can drain, so a shorter interval types a second message into a composer whose first message is still being worked
FM_DELIVERY_ENDPOINT_BACKEND_OVERRIDE=  # explicit backend for `fm-delivery-service.sh publish-endpoint`, for a session whose pane the discovery order cannot see; must be set together with the target override, and both are trusted as given
FM_DELIVERY_ENDPOINT_TARGET_OVERRIDE=   # explicit pane target for that same publish; with neither override set, publish REFUSES rather than guessing an address the listener would type into
FM_DELIVERY_DEFER=10    # seconds before the listener re-reads a pane that said "not now" (busy, unsubmitted text, no endpoint); a deferral delivered nothing, so it is far shorter than the post-submit retry, but re-reading every poll while a captain types costs a capture per second and buys nothing
FM_DELIVERY_GRACE=      # seconds before a delivery beacon reads as stale; falls back to FM_GUARD_GRACE so one fleet has one staleness bar
FM_DELIVERY_SUBMIT_RETRIES=3   # Enter-only retries per submit; the text is typed once and never retyped, because a swallowed Enter leaves it in the composer and a second copy would concatenate into one corrupted turn
FM_DELIVERY_SUBMIT_SLEEP=0.5   # seconds between those Enter retries and the settle read after them
FM_DELIVERY_CONFIRM_TIMEOUT=10   # seconds fm-delivery-service waits to confirm a healthy listener after a start or restart
FM_DELIVERY_STOP_TIMEOUT=20   # seconds fm-delivery-service waits for a recorded listener to exit before treating the stop as failed
FM_DELIVERY_LOG_MAX_BYTES=262144   # size cap on state/.delivery.log before it is trimmed to FM_DELIVERY_LOG_KEEP_LINES
FM_DELIVERY_LOG_KEEP_LINES=500   # lines kept when that log is trimmed
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watcher-service waits to confirm a fresh watcher before reporting failure
FM_TG_RECV_ATTACH_POLL=0.5  # seconds between checks while fm-tg-recv-arm is attached to an existing receiver
FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=2  # seconds fm-tg-recv-arm waits for a competing arm to publish receiver metadata
FM_TG_RECV_TERM_WAIT_CYCLES=30  # termination polling cycles before fm-tg-recv-arm preserves a live receiver lock after wrapper shutdown
FM_TG_RECV_TERM_WAIT_POLL=0.1  # seconds between termination checks during fm-tg-recv-arm cleanup
FM_WATCH_DAEMON=1       # internal: external keeper mode; actionable wake appends continue the watcher loop and skip session-parent reaping
FM_WATCH_MANAGER=       # internal: systemd or keeper identity recorded in state/.watch.lock
FM_WATCH_SOURCE_VERSION= # internal: watcher plus loaded-library content version recorded for bootstrap convergence
FM_WATCH_X_MODE_VERSION= # internal: X-mode environment version recorded for systemd and keeper convergence
FM_WATCH_SERVICE_PATH=  # internal: the composed service PATH the tmux keeper hands its watcher, recorded in state/.watch.lock/service-path for keeper convergence
FM_SERVICE_TOOLS=       # tools bin/fm-service-path-lib.sh resolves when composing a background service's PATH; unset means its own fixed list
FM_SERVICE_REQUIRED_TOOLS='no-mistakes git'   # tools whose absence from a recorded service PATH bootstrap reports as a WATCHER_UNIT line, because losing them degrades supervision silently
FM_SERVICE_PATH_BASE=   # tail every composed service PATH ends with; unset means systemd's user-manager default verbatim
FM_WATCH_STOP_TIMEOUT=20 # seconds the tmux fallback waits for an identity-matched watcher to stop during scoped convergence
FM_EVENT_CAP_REPROBE_SECS=300 # seconds before a long-lived watcher re-probes a disabled Herdr event-wait capability
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before an absorbed stale pane escalates, re-checked against the crew state at that moment: an active run, or a run parked at a decision gate whose worker's agent process is confirmed alive, holds the ladder (bounded recheck once per FM_PAUSE_RESURFACE_SECS), while a crew with neither escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon; also the cadence of the bounded recheck for a wedge ladder held by an active run or by a decision gate whose worker is confirmed alive
FM_WEDGE_REPEAT_RESURFACE_SECS=3600 # maximum quiet window after one possible-wedge alarm for an unchanged pane/current-state class; defaults to FM_PAUSE_RESURFACE_SECS, every suppressed candidate remains in state/.wedge-alarm-history, and a state change re-arms immediate delivery; a continuously unchanged real wedge re-surfaces within this window plus FM_STALE_ESCALATE_SECS and FM_POLL
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive stale escalations on the same unchanged pane/current-state class before demand-deep-inspection is added
FM_WEDGE_ALARM_HISTORY=            # optional path override for the append-only possible-wedge delivery history; defaults to state/.wedge-alarm-history, and failure to append disables suppression for that candidate
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT=10   # seconds allowed for bootstrap's best-effort origin fetch when checking the primary checkout's default branch for self-drift
FM_FIRSTMATE_UPSTREAM_URL=      # highest-precedence currency comparison base for BOTH upstream checks, above config/firstmate-update-base and config/fork-sync-upstream; passed through unvalidated
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by watcher, fm-crew-state pane fallback, and tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
