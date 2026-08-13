---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, ROLE_INVALID, ROLE_OVERLAY_MISSING, NEEDS_GH_AUTH, TANGLE, SELF_DRIFT, CREW_DISPATCH invalid, CURRENCY_BASE, LAVISH_ACCESS, BACKLOG_STALE, BACKLOG_UNREADABLE, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, NUDGE_SECONDMATES, AXI_SUITE_UPDATED, AXI_SUITE_REVIEW, AXI_SUITE_STUCK, AXI_SUITE_SHADOWED, AXI_SUITE_SHADOW_UNKNOWN, FIRSTMATE_UPDATE_AVAILABLE, FIRSTMATE_UPDATE_STUCK, FORK_SYNC, FORK_SYNC_STUCK, CURRENCY_ROUND, MEMORY_ALARM, GROSSREINSCHIFF, WATCHER_UNIT, FREQUENCY_MONITOR_UNIT, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`docs/configuration.md` "Backlog backend" owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because every crew-dispatch profile array calls it automatically; `bin/fm-dispatch-select.sh` still selects uniformly from valid candidates with OS-backed randomness when quota data is unavailable.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `ROLE_INVALID: <name> (known: <names>)` - `config/role` names a role that does not exist, so no overlay was delivered and this session is running unamended `AGENTS.md`.
  Report the concrete consequence to the captain, correct the file to one of the listed values or remove it to return this home to the default `vessel` role, then rerun session start so the overlay actually reaches the session.
  Do not guess which role was meant.
- `ROLE_OVERLAY_MISSING: <name> (expected: roles/<name>.md)` - the selected role is recognized but its tracked overlay file is not present in this code root, so the role's instructions were not delivered.
  Either this home is behind the fork that carries the overlay, in which case `/updatefirstmate` resolves it, or the overlay has not been written yet, in which case the role is not usable and the home should return to `vessel` until it is.
  Do not write the missing overlay from memory to silence the line.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `WATCHER_UNIT: missing ...` or `WATCHER_UNIT: ... disabled ...` - explain that persistent supervision needs the per-home user-service instance, ask for explicit consent, then run `bin/fm-bootstrap.sh install watcher-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment, reloads the user manager, and enables and starts only the instance encoded from this home.
- `WATCHER_UNIT: user lingering is disabled ...` - explain that logout can stop the user manager, ask separately for explicit consent, then run `bin/fm-bootstrap.sh install watcher-linger` only after approval.
  Never run `loginctl enable-linger` from an inference or bundle it into unit-install consent.
- `WATCHER_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, source path or version, X-mode environment, runtime state, or watcher identity.
  Leave repair to the lock-holding session and rerun session start after that session converges the instance.
- `WATCHER_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result and the home-scoped watcher lock and beacon, then report the concrete failure.
  Do not fall back to tmux merely because an otherwise usable systemd manager has a broken installed unit.
- `WATCHER_UNIT: systemd --user unavailable ... tmux keeper fallback ...` - the selected fallback is automatic and needs no captain consent.
  A detect-only session leaves startup to the lock holder; a locked session reports only when the fallback could not establish a healthy watcher.
- `WATCHER_UNIT: systemd --user is unavailable and tmux is not installed ...` - supervision has no restart owner, so do not dispatch until one backend is available.
- `WATCHER_UNIT: the watcher's recorded PATH cannot reach <tools> - crew state will read as unavailable ...` - the named tools are installed here but unreachable from the environment the monitoring service actually runs with, so it cannot read any crew's real state and reports every crew as unavailable instead of failing.
  A locked session converges this by rewriting the service environment, which the same bootstrap step already attempts, so a line that survives convergence needs the concrete tools reported to the captain.
- `WATCHER_UNIT: the watcher's recorded PATH cannot reach <tools>, and this session cannot resolve it either ...` - the recorded service environment was composed by a session that could not reach those tools, so converging again from this session cannot improve it.
  Report the concrete tools, say that the monitoring service was recorded without them, and treat crew-state readings as unreliable until it clears; do not dispatch work whose supervision depends on them.
  Installing a genuinely absent tool remains the `MISSING:` line's business, and repairing it does not by itself fix this one: the service still needs converging from a session that can reach the tool.
- `FREQUENCY_MONITOR_UNIT: missing ...` or `FREQUENCY_MONITOR_UNIT: ... disabled ...` - explain that the configured Bridge inbox remains durable but live-session delivery stays on the slower watcher fallback, ask for explicit consent, then run `bin/fm-bootstrap.sh install frequency-monitor-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment, reloads the user manager, and enables and starts only the instance encoded from this home.
- `FREQUENCY_MONITOR_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, source path or version, environment, or runtime state.
  Leave repair to the lock-holding session and rerun session start after that session converges the instance.
- `FREQUENCY_MONITOR_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result and the home-scoped service environment, then report the concrete failure.
  The original watcher remains the slow delivery backstop.
- `FREQUENCY_MONITOR_UNIT: systemd --user is unavailable ...` - fast Bridge delivery cannot run on this host through the tracked unit, but the original watcher still provides slow durable delivery.
  Do not invent or auto-start an unapproved background-process fallback.
- `AXI_SUITE_UPDATED: <detail>` - the vessel completed a self-repair of its own npm prefix and needs nothing from you; report it only when it materially affects current work.
  `<tool> <old> -> <new>` is a gated patch or minor self-update, `<tool> <version> installed in vessel prefix` is the home's own copy being seeded from the version already on `PATH`, and `<tool> unreadable vessel copy removed from <prefix>` means a copy that could not report its version was dropped so the intact external copy stops being shadowed and a readable version can be reinstalled.
- `AXI_SUITE_REVIEW: <detail>` - a major release, a newly required suite command, or a locally-ahead build the registry cannot supply was deliberately not installed; present the printed install command and purpose to the captain, then use `bin/fm-bootstrap.sh install <approved tool...>` only after consent.
  For the locally-ahead case the external copy keeps working, so the decision is whether to publish that build or let the vessel accept the registry version.
- `AXI_SUITE_STUCK: <detail>` - the vessel could not check or apply an eligible update and persisted the condition in `state/axi-suite-update.stuck`; investigate the local install path first, and if the vessel cannot repair itself, relay the status through the existing Bridge workflow by dispatching a crewmate rather than calling project automation directly.
- `AXI_SUITE_SHADOWED: <tool> runs from <path>, not the maintained copy in <bin>` - the vessel is keeping one copy current while this session runs a different one, so a clean currency report says nothing about the build actually in use.
  Firstmate-launched processes resolve the maintained copies already; this line means the environment this session inherited does not, which is the captain's own shell configuration.
  Report the concrete tools and the two paths, say plainly that the version the vessel maintains is not the version running here, and offer to have him put the printed maintained bin directory ahead of the other one - either per launch, or once for every shell of that home with the login-profile form README.md "Install and launch" documents, which he appends to his own profile himself.
  Never edit his shell configuration to silence it, and never delete the other copy: with the maintained directory absent from that environment, deleting it leaves the tool unrunnable rather than current.
- `AXI_SUITE_SHADOW_UNKNOWN: cannot tell which copy of the suite this session resolves ...` - this is not a shadowing report and not an all-clear; it is the check declining to answer.
  The environment it would have measured was recorded by a different process tree, typically a long-lived tmux server that froze one session's environment into every pane opened after it, so answering either way would describe a session that may be gone.
  Report that the suite's currency is unverified for this session rather than reporting it healthy, and note that a fresh session started outside that server answers the question normally.
  Do not treat it as a reason to install, delete, or reorder anything.
  The condition is retried on the next currency window rather than on every session, so a line that keeps reappearing means the underlying cause is still present.
  A `vessel-prefix seeding ... was not attempted: the <N>s seeding budget is spent` detail is not a broken install: the vessel ran out of its one-time seeding budget, the external copy is still the working fallback, and the next window seeds the rest, so report it only if it survives a second window.
  While seeding runs, the script names each installing tool and the remaining seeding budget on standard error; that progress output is not a diagnostic and needs no handling.
- `FIRSTMATE_UPDATE_AVAILABLE: <detail>` - the configured upstream firstmate has an upstream-only instruction-surface change; dispatch a crewmate to send an All-Ships update notice through the existing Bridge workflow, and never call Bridge project automation directly from firstmate or the check script.
- `FIRSTMATE_UPDATE_STUCK: <detail>` - the read-only upstream framework comparison failed and persisted the condition in `state/firstmate-update.stuck`; investigate the repository or network failure, and do not broadcast an update until the comparison succeeds.
  A `config/firstmate-update-base is unusable` detail is not a network failure: the check refused a configured comparison base, so handle it as `CURRENCY_BASE` below.
- `FORK_SYNC: <detail>` - the curated fork has real-upstream content that is not absorbed under either the original or equivalent history; dispatch one ship crewmate on firstmate itself to merge upstream and re-evaluate `docs/fork-patches.md`, then land that PR with `bin/fm-pr-merge.sh <id> <url> -- --merge` because squashing destroys upstream ancestry.
- `FORK_SYNC_STUCK: <detail>` - the curated-fork comparison failed and persisted the condition in `state/fork-sync.stuck`; investigate the repository, origin, or upstream network failure before dispatching a sync cycle.
  A `config/fork-sync-upstream is unusable` detail is not a network failure: the check refused a configured comparison base, so handle it as `CURRENCY_BASE` below.
- `CURRENCY_ROUND: <detail>` - this home's daily update check is not running, so nothing is watching for updates between sessions and its silence proves nothing.
  `not armed` or `could not be armed` means the check was never installed or the arm failed; run `bin/fm-currency-round.sh --arm` and report the reason if it refuses.
  `armed ... and has never completed a round` or `stopped being checked` means the check exists but the monitoring service is not running it, which is a supervision fault rather than a currency one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never treat this line as a currency verdict - it says the instrument is not reading, not that this home is behind.
  The findings the round itself raises arrive as a `check:` wake, not here; run `bin/fm-currency-round.sh --status` for the full round when you need every reading.
- `MEMORY_ALARM: <detail>` - nothing is watching this machine for memory exhaustion, which on a host with no swap and no limit anywhere means the first sign of trouble would be the kernel killing something.
  `nothing is watching` or `could not be armed` means the alarm was never installed or the arm failed; run `bin/fm-memory-alarm.sh --arm` and report the reason if it refuses.
  `has never completed a reading` or `has stopped running` means the alarm exists but the monitoring service is not running it, which is a supervision fault rather than a memory one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never read this line as a verdict on memory - it says the instrument is not reading, not that this machine is fine; `bin/fm-memory-alarm.sh --status` gives the current reading when you need it.
  An actual crossing or recovery arrives as a `check:` wake instead, and that one is captain-facing: it names a process, an account, and the work it was serving, and nothing has been limited or killed, so the decision is still open.
- `GROSSREINSCHIFF: weekly fleet cleanup sweep is due (...)` - this home has not completed its Thursday cleanup sweep for the current week; load the `grossreinschiff` skill and run it.
  Nothing is broken: the line is a cadence reminder, and it repeats each session start until `bin/fm-grossreinschiff-due.sh --record` marks a sweep that actually produced a report.
  The reported window-open days say only how far into the current week's window this session start falls; the count is bounded to 0 through 6 and never measures how long the home has been dark.
  Judge staleness from the `last swept:` date in the same line: a date more than one week before the current Thursday means whole weeks were missed, and that is what is worth reporting to the captain.
  In a session that did not get the fleet lock this line is advisory only: the sweep changes records, so the session holding the lock owns it - note it and leave it.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `SELF_DRIFT: <detail>` - the primary checkout's default branch is ahead of, behind, or diverged from its own origin and bootstrap left it untouched; use `/updatefirstmate` only for a clean fast-forward case, otherwise dispatch a manual recover-by-merge crewmate task that preserves the local commits.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `CURRENCY_BASE: config/<file> is unusable - <reason>; <remediation>` - the home configured a comparison base for one of the two upstream checks, but the file cannot be used, so that check refuses rather than silently comparing against the wrong source.
  Fix the named file to one non-empty git URL or absolute path, or remove it to fall back to the canonical upstream template; `docs/configuration.md` "Upstream firstmate and curated-fork checks" owns which check reads which file and why they are separate.
  Until it is fixed, treat that check's currency signal as absent rather than as evidence the deployment is current.
- `LAVISH_ACCESS: <N> open review board link(s) still point at this machine only ...` - this vessel has a tailnet, so those boards could be reachable, but the links already handed over open nothing on the captain's own devices.
  Nothing is broken and nothing is at risk; the boards work locally, and the failure is silent precisely because they look correct here.
  Reopen each affected board with `bin/fm-lavish.sh <html-file>`, which moves it onto this vessel's tailnet address and prints the new link, then give the captain that new link if he was already sent the old one.
  Do not hand-set the `LAVISH_AXI_*` variables to silence this: a server that is already running keeps emitting the hostname it was started with, so only reopening through the wrapper actually changes the link.
  The check is detect-only, stays silent on a host with no tailnet, and repeats each session start until the affected sessions are reopened or ended.
- `BACKLOG_STALE: task <id> has <fault>; fix: <command>` - a current durable backlog record has a mechanically stale dependency edge.
  Inspect the named record and apply the exact printed fix, and add the intended existing blocker afterward only when the dangling id was a typo.
  The fix is a `tasks-axi unblock` command only when that command would actually run; when the clause instead names a hand edit to `data/backlog.md` - because `config/backlog-backend` is `manual`, or because the line says no tasks-axi fix is available since tasks-axi cannot resolve that record - delete the quoted `blocked-by:` token from the named record by hand and do not substitute a `tasks-axi` command for it.
  The check itself is detect-only and must never run the repair command, block startup, or mutate retention behavior.
- `BACKLOG_UNREADABLE: task <id> in <backlog file> is parsed by fm-fleet-snapshot but tasks-axi does not list that record when reading the same file ...; fix: <row repair>` - the two structured readers cannot be compared on that one record, so whether its archived-target edges are stale stayed undecided and none was reported.
  This is a malformed-record report, not a stale-edge finding, and it marks a deliberate miss rather than a guess: only the reader-disagreement class needs tasks-axi's own answer, so that record's dangling and already-Done edges are still reported as `BACKLOG_STALE` with hand-edit fixes, and the rest of the backlog is still checked.
  Open the named row in the named backlog file and check the id token first, because `tasks-axi` resolves only a slug-shaped id (letters, digits, `.`, `_`, `-`, no spaces and no Markdown emphasis) inside a `- [ ] <id> - <title>` row, while `fm-fleet-snapshot` also accepts a `- **<id>** - <title>` row.
  Rewrite the id or the row shape, then confirm the repair with `tasks-axi list --file <backlog file>` showing that id.
  It repeats every session start until the row is fixed, it never blocks startup, and the check must not rewrite the row itself.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - the local-HEAD secondmate sync left a live secondmate home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing the primary target commit, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed: <reason>` - the session-start liveness sweep could not guarantee that a live secondmate's recorded endpoint is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - the secondmate sweep fast-forwarded a running secondmate home and its loaded instruction surface (`AGENTS.md`, `bin/`, `roles/`, or `.agents/skills/`) changed, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  The same locked bootstrap pass converges an already-installed watcher service against the generated X-mode environment, including a scoped restart when the process inherited stale cadence.
