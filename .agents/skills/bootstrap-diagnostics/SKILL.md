---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, NEEDS_GH_AUTH, SELF_DRIFT, CURRENCY_ROUND, MEMORY_ALARM, RUN_READER, VALIDATION_DAEMON, TELEGRAM_RECEIVER_UNIT, GROSSREINSCHIFF, SLOT_GUARD, or any of the other prefixes this playbook's body carries an entry for, the full set being the lines bin/fm-bootstrap.sh's header documents - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
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
  Either this home is behind the update source that carries the overlay, in which case `/updatefirstmate` resolves it, or the overlay has not been written yet, in which case the role is not usable and the home should return to `vessel` until it is.
  Do not write the missing overlay from memory to silence the line.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `FORGE_CLIENT: ...` - this home names a Forgejo instance, so it needs the same Forgejo client to resolve for both a session and the validation pipeline, with the daemon-resolved executable at or above the floor, and some part of that requirement was not established.
  Read which sentence the line carries before acting, because only a line that prints an install command includes an install.
  `is not installed where both this session and the validation pipeline can run it` means the client is absent from the pipeline daemon's own PATH; `command -v forgejo-axi` answering yes in your session does not contradict it and is not evidence against the line.
  Pass `forgejo-axi` to `bin/fm-bootstrap.sh install` after the captain approves, exactly as for `MISSING:`, and never install it somewhere else to silence the line - the printed prefix is chosen because the pipeline daemon already reaches it, and a copy anywhere else leaves the requirement failing.
  When that install text also says `make <bin> reachable from an agent session's PATH`, the install alone is incomplete: apply the named session-side PATH repair too, because the selected prefix is daemon-reachable but not session-reachable.
  `below the required <floor>` with a printed install command is the same repair against the daemon-resolved copy being too old.
  `meets the required <floor> floor for the validation pipeline, but this session resolves no forgejo-axi` is NOT an install: repair the session's `PATH` so it reaches the daemon-resolved executable.
  `meets the required <floor> floor for the validation pipeline, but this session resolves a different copy` is NOT an install: repair the session's `PATH` ordering or shadowing so both environments resolve the daemon-measured executable.
  `the pipeline daemon's PATH names no user-owned directory this fleet can install into` is NOT an install, even when the same line reports absence or an old version: the daemon's own `PATH` must first name a user-owned bin directory.
  `cannot read the validation pipeline daemon's environment` is NOT an install: it means this seat could not be asked the question at all, so report it to the captain as unestablished rather than as a working or a broken client, and never let it stand as an all-clear.
  `docs/forgejo-axi-adoption.md` owns why the floor is what it is, the maintenance risk this dependency carries, and what this check cannot cover.
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
- `DELIVERY_UNIT: missing ...` or `DELIVERY_UNIT: ... disabled ...` - explain that without it nothing turns a queued wake into a turn, so the fleet would keep detecting work and never surface it, ask for explicit consent, then run `bin/fm-bootstrap.sh install delivery-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment, reloads the user manager, and enables and starts only the instance encoded from this home.
- `DELIVERY_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, source path or version, runtime state, or listener identity; leave repair to the lock-holding session.
- `DELIVERY_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result and this home's listener lock and beacon, then report the concrete failure.
- `DELIVERY_UNIT: systemd --user unavailable ... tmux keeper fallback ...` - the selected fallback is automatic and needs no captain consent.
- `DELIVERY_UNIT: systemd --user is unavailable and tmux is not installed ...` - nothing can supervise a listener here, so queued wakes will sit undelivered; do not dispatch until one backend is available.
- `DELIVERY_UNIT: the listener's recorded PATH cannot reach <tools> ...` - the same two forms as the watcher's PATH lines above, with the same repair; a listener that cannot reach its session-backend CLI cannot submit a wake at all.
- `TELEGRAM_RECEIVER_UNIT: missing ...` or `TELEGRAM_RECEIVER_UNIT: ... disabled ...` - explain that the configured receiver still depends on a session-owned fallback and therefore stops when that session does, ask for explicit consent, then run `bin/fm-bootstrap.sh install telegram-receiver-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment without copying or printing its credential, reloads the user manager, and enables and starts only the instance encoded from this home.
- `TELEGRAM_RECEIVER_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, receiver or wrapper bytes, environment, or runtime state; leave repair to the lock-holding session.
- `TELEGRAM_RECEIVER_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result, run `bin/fm-tg-recv-service.sh status`, and inspect only the home-scoped lock and wake record; never print or source the credential while diagnosing it.
- `TELEGRAM_RECEIVER_UNIT: systemd --user is unavailable ...` - the session-owned tracked task remains the explicit fallback, so receive works only while that task and its session remain alive.
- `RESPAWNER_UNIT: missing ...` or `RESPAWNER_UNIT: ... disabled ...` - explain that queued wakes can still pile up beside a dead primary seat unless the per-home respawner is installed, ask for explicit consent, then run `bin/fm-bootstrap.sh install seat-respawner-unit` only after approval.
- `RESPAWNER_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, source path or version, runtime state, or service environment; leave repair to the lock-holding session.
- `RESPAWNER_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result, the home-scoped respawner lock and beacon, `state/.seat-respawner.log`, and the configured fresh launch command.
- `RESPAWNER_UNIT: systemd --user is unavailable ...` - no supervised respawner can run on this home, so a dead primary seat still requires manual relaunch.
- `RUN_READER: no-mistakes runs in this session (<path>) but a context that inherits no shell setup cannot reach it ...` - the validation tool that answers for a crew's real run state is installed somewhere only an interactive shell reaches, so this session reads true state while the monitoring service, the hooks, a fresh login and any independent reviewer read a refusal instead.
  Report it as a real instrument fault, because the refusal is not inert: a reviewer that cannot see a decision resolved keeps re-reporting it as outstanding after every answer, which manufactures pending work that does not exist.
  Follow the printed repair - put the tool where the seat's install location is, or name that location explicitly - and re-run session start to confirm the line clears; do not treat run-state readings from unattended sources as reliable until it does.
  This is the SEAT-wide question and the `WATCHER_UNIT: ... recorded PATH cannot reach ...` pair is the one recorded service's, so a repair here does not clear one of those, and neither of those clears this.
  A tool that is not installed at all belongs to the `MISSING:` line instead, and this one deliberately stays quiet for that case.
- `VALIDATION_DAEMON: the validation pipeline daemon is not running ...` - the daemon behind every review gate on this account is down, so every run parked on it is unanswerable and no worker will discover it until one tries to answer its own gate and gets a refused socket back.
  Run the printed repair, `no-mistakes daemon start`, and re-run session start to confirm the line clears; parked runs survive the outage and are listed again as soon as it is back.
  Never repair it with `no-mistakes update`: that resets the daemon as part of upgrading the tool, so it would carry a version change into runs that are already parked inside the old one.
  The daemon is per-ACCOUNT rather than per-home - one socket serving every firstmate home and secondmate on the account - so a start here is a fleet-visible action, not a local one; that is also why bootstrap reports it instead of starting it (docs/validation-daemon.md).
  Expect the same line from every home on the account, and treat the duplication as correct rather than as a fault: each of those homes really is impaired, and one repair clears all of them, so do not start the daemon once per line.
  The line never names how many homes are behind the socket, because no home can count its siblings; do not supply a number it did not print.
- `VALIDATION_DAEMON: whether the validation pipeline daemon is running is unestablished - <reason> ...` - this is not an all-clear and not a report that it is down; it is the check declining to answer.
  `did not answer within <N>s` means a wedged daemon rather than a dead one, and a restart there kills whatever in-flight run wedged it, so read it by hand first and treat any restart as the account-wide action it is.
  `answered in a shape this check does not recognise` means the external tool's output changed under this fleet, so take the reading by hand and treat the check itself as needing an update.
  `neither timeout nor gtimeout` means this seat cannot bound the call, and asking unbounded would hang session start behind a wedged daemon.
  `below the version floor this fleet requires` and `answered with no version this check could read` both mean the installed CLI cannot be asked at all, so these reasons carry the upgrade as their repair instead of a daemon command, and the `MISSING: no-mistakes` line names the same upgrade.
  Those two are different readings and the line says which one it took: `below the version floor this fleet requires` established a version and found it too old, while `answered with no version this check could read` established no version at all, so do not report an unreadable version as an out-of-date CLI.
  `refused daemon status as a command it does not have` is the same blocker one version band higher and carries the same upgrade: the installed CLI is old enough not to have the daemon verbs, so a hand reading would be refused exactly as the check's was.
  Never relay the silence as healthy on any of these paths, whichever reason the line carries.
  On the timeout, unrecognised-shape and no-bounding-command reasons take the reading yourself with `no-mistakes daemon status` before concluding anything, because the CLI can still answer on those.
  On either version reason, and on the refused-command one, do the upgrade the line names first instead, because neither daemon verb can succeed until it lands; the ban on `no-mistakes update` still holds, and the printed upgrade is the installer script rather than that path.
- `FREQUENCY_MONITOR_UNIT: missing ...` or `FREQUENCY_MONITOR_UNIT: ... disabled ...` - explain that the configured Bridge inbox remains durable but live-session delivery stays on the slower watcher fallback, ask for explicit consent, then run `bin/fm-bootstrap.sh install frequency-monitor-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment, reloads the user manager, and enables and starts only the instance encoded from this home.
- `FREQUENCY_MONITOR_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes, source path or version, environment, or runtime state.
  Leave repair to the lock-holding session and rerun session start after that session converges the instance.
- `FREQUENCY_MONITOR_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result and the home-scoped service environment, then report the concrete failure.
  The original watcher remains the slow delivery backstop.
- `FREQUENCY_MONITOR_UNIT: systemd --user is unavailable ...` - fast Bridge delivery cannot run on this host through the tracked unit, but the original watcher still provides slow durable delivery.
  Do not invent or auto-start an unapproved background-process fallback.
- `BOSUN_UNIT: missing ...` or `BOSUN_UNIT: ... is disabled ...` - the home opted into the observer tier but nothing keeps it running between sessions, so it judges only while someone is watching it.
  Explain that it observes and records and changes nothing about what reaches the captain, that it spends an agent turn per judgement, ask for explicit consent, then run `bin/fm-bootstrap.sh install bosun-unit` only after approval.
  The installation copies the tracked template, writes this home's private environment, reloads the user manager, enables only the instance encoded from this home, and unconditionally restarts it so an already-running instance loads the recorded configuration.
  A running observer that reads `STALLED` or `BLIND` is restarted only after its evidence is recorded on the findings surface.
- `BOSUN_UNIT: <instance> needs locked convergence ...` - this read-only session found stale unit bytes or a stale recorded environment; leave repair to the lock-holding session and rerun session start after it converges.
- `BOSUN_UNIT: <instance> convergence failed ...` - inspect the named `systemctl --user status` result and this home's recorded service environment, then report the concrete failure.
- `BOSUN_UNIT: nothing is being judged - <STATE>: <detail>` - this is the reading that matters, and it is taken from the observer's own work rather than from whether the unit says active.
  `STOPPED` and `DEAD` mean no observer process is consuming the event stream; a locked session converges those automatically, so seeing one means the repair did not hold and the concrete failure needs inspecting.
  `STALLED` means one IS running and its cursor has frozen while the stream grew, and `BLIND` means it cannot read the stream at all.
  Neither is restarted without a record: absent configuration drift it is left alone, while a drift-driven restart first leaves a durable high-severity evidence record on the findings surface for the watcher and supervising session to read with `bin/fm-finding.sh list`.
  If that record cannot be written, the restart is blocked and the `BOSUN_UNIT:` line names the unreachable surface and its initialization command.
- `BOSUN_UNIT: the observer's recorded PATH cannot reach its judge <program> ...` - it would keep running and keep reporting healthy while recording every event as an unjudged escalation.
  Either install the named judge where the recorded environment reaches it, or converge the service from a session that already resolves it.
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
- `FIRSTMATE_UPDATE_AVAILABLE: <detail>` - the configured update source has a source-only instruction-surface change; dispatch a crewmate to send an All-Ships update notice through the existing Bridge workflow, and never call Bridge project automation directly from firstmate or the check script.
- `FIRSTMATE_UPDATE_STUCK: <detail>` - the read-only update-source comparison failed and persisted the condition in `state/firstmate-update.stuck`; investigate the repository or network failure, and do not broadcast an update until the comparison succeeds.
  A `config/firstmate-update-base is unusable` detail is not a network failure: the check refused a configured comparison base, so handle it as `CURRENCY_BASE` below.
- `CURRENCY_ROUND: <detail>` - this home's daily update check is not running, so nothing is watching for updates between sessions and its silence proves nothing.
  `not armed` or `could not be armed` means the check was never installed or the arm failed; run `bin/fm-currency-round.sh --arm` and report the reason if it refuses.
  `armed ... and has never completed a round` or `stopped being checked` means the check exists but the monitoring service is not running it, which is a supervision fault rather than a currency one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never treat this line as a currency verdict - it says the instrument is not reading, not that this home is behind.
  The findings the round itself raises arrive as a `check:` wake, not here; run `bin/fm-currency-round.sh --status` for the full round when you need every reading.
- `MEMORY_ALARM: <detail>` - nothing is watching this machine for RAM-headroom loss, runaway growth, or memory stall held continuously past the window; swap is a shock absorber rather than an all-clear, and any future memory limit is outside this alarm.
  `nothing is watching` or `could not be armed` means the alarm was never installed or the arm failed; run `bin/fm-memory-alarm.sh --arm` and report the reason if it refuses.
  `has never completed a reading` or `has stopped running` means the alarm exists but the monitoring service is not running it, which is a supervision fault rather than a memory one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never read this line as a verdict on memory - it says the instrument is not reading, not that this machine is fine; `bin/fm-memory-alarm.sh --status` gives the current reading when you need it.
  An actual crossing or recovery arrives as a `check:` wake instead, and that one is captain-facing: it names a process, an account, and the work it was serving, and nothing has been limited or killed, so the decision is still open.
- `GITHUB_INBOX: <detail>` - this home armed the GitHub notification watch and it has stopped reading, so threads addressed to this fleet are going unread.
  It appears only on a home that armed it: watching one notification feed from several homes would have each of them surface the same threads separately, so arming is a per-home decision and silence here means this home did not opt in (docs/github-inbox.md).
  `cannot run` means the check file lost its executable bit; run `bin/fm-github-inbox.sh --arm` and report the reason if it refuses.
  `has never completed a reading` or `has stopped running` means the watch exists but the monitoring service is not running it, which is a supervision fault rather than a GitHub one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never read this line as a verdict on the feed - it says the instrument is not reading, not that nobody has written to this fleet; `bin/fm-github-inbox.sh --status` gives the current reading when you need it.
  Threads actually addressed to this fleet arrive as a `check:` wake instead, carrying the link and what happened, and an unreadable feed says so there rather than passing as an empty inbox.
- `CURATION_NUDGE: <detail>` and `CODEBASE_SWEEP_NUDGE: <detail>` - one of this home's off-grid fleet nudge subjects is unavailable or has raised its wake.
  Both codes come from the one check `bin/fm-nudge.sh`, which carries the curation subject on a 48-hour period and the codebase-design sweep subject on a 52-hour one, so the detail vocabulary below is the same for both and only the subject differs.
  Two codes arriving together therefore usually name one fault of the shared check rather than two independent ones; fix the shared condition once and re-read.
  `is not armed` or `could not be armed` means the check was never installed or the arm failed; run `bin/fm-nudge.sh --arm` and report the reason if it refuses.
  `state persistence failure` means the state path cannot publish that subject's authoritative record; repair its permissions, disk space, quota, or mount, not monitoring.
  `supervision outage` means the state path is usable but the schedule is still missing or overdue; repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  `state health indeterminate` names state publication failure and supervision outage as candidates while asserting neither; check both, starting with the cheaper state-path reading, and do not route it as either verdict.
  These readings are worth trusting because they come from what the work produced plus an observation-time publishability probe, not from the check's own claim to be armed; `bin/fm-nudge.sh --status` prints every subject's authoritative record when you need it.
  Never read either line as a verdict on any vessel's files or repositories, including this one.
  The nudge itself arrives as a `check:` wake instead, and that one asks firstmate to dispatch a crewmate to send the All-Ships notice per `AGENTS.md` section 12; the wording of that notice is firstmate's, and the nudge never writes to Bridge itself.
  For `CURATION_NUDGE` each vessel then measures its own `data/learnings.md` and `data/captain.md` and decides its own split, because the files are per-home and gitignored and no seat can see another's.
  For `CODEBASE_SWEEP_NUDGE` each vessel loads the `codebase-sweep` skill and runs it on its own repositories, one named repository at a time; the cadence sweeps nothing and reads no repository, here or anywhere.
- `FORGE_STATUS: <detail>` - this home's forge status watch is unavailable, or its scheduler cannot place a next observation.
  `is not armed` or `could not be armed` means the watch was never installed or the arm failed; run `bin/fm-forge-status.sh --arm` and report the reason if it refuses.
  `state persistence failure` means the state path cannot publish the record or append the reading log; repair its permissions, disk space, quota, or mount, not monitoring.
  `supervision outage` means the state path is usable but the observation is still missing or overdue, so the forge is unwatched; repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  `state health indeterminate` names state publication failure and supervision outage as candidates while asserting neither; check both, starting with the cheaper state-path reading.
  `landed on the five-minute grid` is a scheduling refusal, not dead monitoring: the configured jitter window contains no off-grid target minute, so widen it.
  Never read any of these lines as a reading of the forge itself - they say the instrument is not reading, never that the forge is healthy; `bin/fm-forge-status.sh --status` and `--log` print what was actually recorded.
  A reading arrives as a `check:` wake instead, and that one is firstmate's to judge: decide whether it touches this fleet's work, whether the fleet needs telling through a dispatched crewmate per `AGENTS.md` section 12, and whether to raise or lower the watch with `bin/fm-forge-status.sh --cadence raised|relaxed`.
  A wake that says `UNMEASURABLE` means this seat could not read the status page; it is never relayed as an all-clear (docs/forge-status-watch.md).
- `SLOT_GUARD: <detail>` - nothing is watching for a pooled worktree that two tasks both claim, which is the condition that lets a cleanup return a copy a running worker is standing in and destroy its unsaved work.
  `nothing is watching` or `could not be armed` means the watch was never installed or the arm failed; run `bin/fm-slot-guard.sh --arm` and report the reason if it refuses.
  `has never completed a sweep` or `has stopped running` means the watch exists but the monitoring service is not running it, which is a supervision fault rather than an ownership one: repair it through the emitted supervision instructions, exactly as for a lapsed watcher.
  Never read this line as a verdict on whether any slot is currently contested - it says the instrument is not reading, not that the fleet is clear; `bin/fm-slot-guard.sh --status` gives the current reading of every recorded copy when you need it.
  An actual contested copy arrives as a `check:` wake instead, and it names both the finished task and the live worker standing in its copy.
  That wake is captain-facing only when it blocks a cleanup he is waiting on: cleanup of the named task is already refused, and the work of the live worker is not at risk while the refusal stands, so the ordinary handling is to let the live worker finish and then retry the cleanup.
  Never resolve one by forcing the cleanup through: `--force` deliberately does not override this refusal, because authority to discard one task's work is not authority to destroy another's.
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
- `CURRENCY_BASE: config/<file> is unusable - <reason>; <remediation>` - the home configured the instruction-surface comparison base, but the file cannot be used, so that check refuses rather than silently comparing against the wrong source.
  Fix the named file to one non-empty git URL or absolute path, or remove it to fall back to the deployment update source; `docs/configuration.md` "Firstmate update-source check" owns which file it reads.
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
- `DECISION_LEDGER: <class> <id> - <detail>` - a captain decision record in this home is structurally unfinished, found by `bin/fm-decision-ledger.sh --audit`.
  Every class is a repair, never a fresh question for the captain: he has already answered, or the answer is already lost, and asking him again is precisely the failure this check exists against.
  Load `decision-hold-lifecycle` before touching any of them.
  `unfinished-close` means the decision is stored but the close did not finish; re-run the identical `bin/fm-decision-hold.sh record` call, which is idempotent and completes it.
  `acted-but-open` means a held decision blocks only tasks that are all done, so the answer was given and acted on but never recorded; find his actual words and record them, and do not invent them if you cannot.
  `closed-without-record` means this closed row carries no answer; when the finding names an answered record, read both questions and use its printed `answered-by` command only if that record answers this one, otherwise the answer remains lost.
  `altered-record` means the stored answer no longer matches what was recorded; say so plainly to the captain rather than acting on text that cannot be trusted, because a wrong answer presented as settled is worse than an open question.
  `answer-pointer-broken` means an `answered-by` attestation no longer resolves to the answered captain record and digest it named; verify the actual answer record before re-attesting with the command in the finding.
  `stale-body-state` means a closed record still says in its own text that it awaits a decision; correct the text, and do not read the text as evidence the question is open.
  `duplicate-suspect` and `open-but-settled` mean several records may be asking one question, or a question already has a recorded answer; read them and fold what you confirm with `bin/fm-decision-hold.sh supersede`, and never report the count of these findings as the number of duplicates, because this check cannot see one question re-asked in different words.
  `premise-unmeasurable` means a record's premise could not be measured from the seat that tried; **do not fold it on that reading** - the finding may still be live on the machine where it was made, and a fold would close it with nobody left who could see it.
  The check is detect-only, repeats every session start until the record is repaired, and never closes a captain decision on its own.
- `DECISION_LEDGER: baseline absent - <n> of the findings above sit on captain records that are already closed ...` - this home has never taken an adoption baseline, so the audit is still reporting losses that predate the mechanism and can never be repaired.
  Read the listed findings once and decide whether those answers are genuinely lost rather than pending; if they are, run `bin/fm-decision-ledger.sh --record-baseline` once, which records that fact and lets the check converge on the records still worth repairing.
  On the main home this was the difference between 58 findings every session and 2, so leaving it untaken is what makes the whole check unreadable.
- `DECISION_LEDGER: baseline recorded - <n> finding(s) ... are withheld` - a disclosure, not a problem: the audit is withholding that many findings on records that were already closed when the baseline was taken, and it says so every run rather than hiding them.
  No action.
  The withheld findings are listed in the named file and still carried under `baseline_excluded` by `--audit --json`.
- `DECISION_LEDGER: baseline rejected - <n> line(s) ... name a finding class that sits on a live record` - the baseline file has lines that reach for a record that is still repairable, and they carry no authority: a baseline may only ever cover an already-closed record.
  Every finding those lines name is still being reported.
  Remove the offending lines and repair the records they point at.
- `DECISION_LEDGER: and <n> more not shown here ...` - the startup digest caps how many findings it prints and states the remainder rather than truncating silently; run `bin/fm-decision-ledger.sh --audit` for the full list.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `FLEET_SYNC: fleet: STUCK: cannot read the project registry <path>: <cause>` - the home's `data/projects.md` is present and could not be read, so the whole-fleet refresh stopped before the walk rather than reporting that this home has no projects.
  The cause names what it hit: `permission denied`, `not a regular file`, `broken symlink to <target>`, `the registry could not be parsed`, or `cannot tell whether the registry exists: <dir> cannot be searched` when an ancestor directory blocks even the look.
  Repair the named path or its permissions; a home that registers nothing has no such file and is not reported here.
- `FLEET_SYNC: fleet: STUCK: cannot list the projects directory <path>: <cause>` - the home's projects dir is present and could not be listed, so every unregistered clone in it would have dropped out of the refresh silently.
  Same cause vocabulary as the registry line, plus `the projects directory could not be listed` for a directory that passes its mode check and still cannot be read.
- `FLEET_SYNC: fleet: refresh failed (exit <rc>); the outcomes above are only what it managed before stopping` - the background refresh did not run to completion, so the per-project lines above it are partial rather than the whole fleet.
  Read the refusal that precedes it for the cause; an exit status with no other fleet line means the refresh stopped before it could report on any clone.
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
