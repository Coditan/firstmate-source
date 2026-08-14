# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Record the primary session's transcript position, then print the native session-start hook nudge when it has not already run the digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-axi-suite.sh`        | Check and gate patch/minor self-updates of the npm-distributed AXI CLI suite, and report when the maintained copy is not the copy this session runs |
| `fm-axi-path-lib.sh`     | Resolve and prepend one vessel's home-private AXI npm prefix, record the pre-prepend session PATH, and name the maintained tools something else shadows |
| `fm-currency-round.sh` | Run this home's daily currency round, arm it on the watcher, and report a home that has stopped being checked |
| `fm-firstmate-update-check.sh` | Read-only check for relevant instruction-surface commits on the source this deployment updates from |
| `fm-fork-sync-check.sh` | Detect unabsorbed real-upstream content in the curated fork and prefilter both sides of its commit review |
| `fm-grossreinschiff-due.sh` | Report whether this home's weekly Thursday cleanup sweep is due, and record a completed one |
| `fm-lint.sh`             | Single owner of firstmate's shell-lint definition: file set, config, and pinned ShellCheck version |
| `fm-install-shellcheck.sh` | Install CI's pinned, checksum-verified ShellCheck build `fm-lint.sh` requires      |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-backlog-lint.sh`     | Detect-only report of mechanically stale `blocked-by:` edges in the durable backlog  |
| `fm-blocker-class-lib.sh` | Shared jq predicate for whether a `blocked-by:` target is real in the live backlog or done archive |
| `fm-decision-hold.sh`    | Create, verify, complete, and resolve durable captain-held decisions                 |
| `fm-decision-inventory.sh` | Group the open captain decisions by originating investigation and keep the judge's record where a judge ruled, for `/decisionboard` (the fold is assumed, not verified) |
| `fm-sea-chart.sh`        | Assemble one undertaking's sea chart - destination, decided, takeable, fog, course boundaries - for `/sea-chart`, reconciling its own decision records back against the backlog so a withheld one is counted rather than dropped; amends Wayfinder by Matt Pocock under the MIT licence (docs/sea-chart-provenance.md) |
| `fm-chart-kinds-lib.sh`  | The `fog` and `out-of-course` backlog kinds, spelled once for every reader of them |
| `fm-to-backlog.sh`       | File one captain-approved breakdown into the backlog in dependency order under the originating undertaking's id, refusing a cycle, an edge that could never clear, a missing origin or blocker, an unspecified unit, and a kind or reserved id marker owned elsewhere, for `/to-backlog`; adopts to-tickets by Matt Pocock under the MIT licence (docs/to-backlog-provenance.md) |
| `fm-finding.sh`          | Append to and read the political officer's findings surface: create it, emit a finding, list, show, and check a surface that reports unreachable as its own reading rather than as empty (docs/findings-surface.md) |
| `fm-finding-lib.sh`      | The findings surface's record contract, spelled once for the emit and drain sides: where the surface is, what a finding and an outcome are checked against, and the severity-to-deadline table the queue sorts by |
| `fm-finding-drain.sh`    | Take findings off that surface by earliest deadline first, list the overdue ones, and write each drained finding's outcome back as a sibling record the officer cannot create (docs/findings-surface.md) |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-model-panel.sh`      | Run a model panel: two independent analysts on different models, then a judge that re-verifies both |
| `fm-grade.sh`            | Grade review quality on git-derived and blind evidence rather than the reviewed tool's own ledger (docs/review-grading.md) |
| `fm-supervision-cost.sh` | Measure what supervision costs a session in freshly written tokens, from the provider's own usage records (docs/supervision-cost.md) |
| `fm-supervision-cost-engine.py` | Measurement engine for supervision spend; counts session starts, deliveries, empty deliveries, requests per wake, and delivery arms by whether they cost a request of their own |
| `fm-grade-engine.py`     | Measurement engine for the review-quality scale; every metric carries its evidence class and sample size |
| `fm-memory-reading.sh`   | Name which process is running away with this machine's memory, by size and by growth, tied to its account and to its task when known, alongside headroom and the kernel's stall reading; it sets no limit and kills nothing, and it never reports an input it could not read as a healthy zero (docs/memory-attribution.md) |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Phase 2 concurrent isolation proof and proven-isolated candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the supervision-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the supervision-arm PreToolUse policy (docs/arm-pretool-check.md) |
| `fm-continuity-pretool-check.sh` | Narrow Claude recovery gate when in-flight work has no live watcher lock (docs/arm-pretool-check.md) |
| `fm-continuity-command-policy.mjs` | Semantic owner of Claude continuity-gate fleet-command classification (docs/arm-pretool-check.md) |
| `fm-cd-pretool-check.sh` | Stable PreToolUse transport for the cd-guard command policy (docs/cd-guard.md)       |
| `fm-cd-command-policy.mjs` | Semantic owner of the cd-guard PreToolUse policy (docs/cd-guard.md)               |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-lavish-pretool-check.sh` | Stable PreToolUse transport for the lavish-guard command policy (docs/lavish-access.md) |
| `fm-lavish-command-policy.mjs` | Semantic owner of the bare-`lavish-axi` PreToolUse policy (docs/lavish-access.md) |
| `fm-lavish.sh`           | Open review boards on this vessel's own tailnet address and port (docs/lavish-access.md) |
| `fm-board.sh`            | Build a review board on the shared standard layout and refuse one that reaches the network (docs/board-layout.md) |
| `fm-service-port.sh`     | Resolve one vessel-local service's reachable address and a port it actually bound     |
| `fm-service-port-probe.mjs` | Bind, DNS, and readiness oracle for the service-port allocator                    |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-secondmate-state.sh` | Atomically set a persistent secondmate's parent-home `active`/`resting` lifecycle state |
| `fm-dispatch-select.sh`  | Resolve a dispatch rule/default to one profile, owning quota-aware arrays and random fallback |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-role-lib.sh`         | Shared vessel-role selection and tracked `roles/<name>.md` overlay resolution         |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/herdr-eventwait.py` | Raw AF_UNIX subscriber transport for herdr's native `pane.agent_status_changed` push stream (docs/herdr-backend.md) |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live secondmates mid-session and send a pointer to the literal-content config reread when config changed |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-bridge-relay.sh`     | Guardedly relay envelope-only `send`/`inbox`/`status`/`broadcast` calls to the coditan-bridge checkout's own scripts, refreshing it through fleet sync first and refusing a read it cannot prove current |
| `fm-review-diff.sh`      | Review a crewmate branch or recorded PR head against the authoritative base          |
| `fm-pdf-finish.sh`       | Assemble a generated PDF through a conforming producer and publish it only if the gate passes (docs/pdf-output.md) |
| `fm-pdf-verify.sh`       | Refuse a PDF a real reader cannot read as spec-conforming; fails closed when it cannot check |
| `fm-pdf-lib.sh`          | Shared `--pages`/`--quiet` parsing and Ghostscript resolution for both PDF scripts    |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-mark-parked.sh`      | Validate and declare an ordinary terminal task parked through a seatbelt-safe wrapper |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and one-shot escalation |
| `fm-secondmate-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watcher-service.sh`  | Select, converge, install, or restart the home-scoped systemd or tmux watcher keeper |
| `fm-service-path-lib.sh` | Compose the `PATH` a background service must run with, and name the installed tools a recorded one cannot reach |
| `fm-frequency-monitor-service.sh` | Detect, converge, or explicitly install the home-scoped Bridge frequency monitor unit |
| `fm-frequency-monitor.sh` | Run the fast plain-shell Bridge fetch, deduplication, and durable wake loop           |
| `fm-bridge-inbox-lib.sh` | Share lock-protected Bridge inbox signatures and durable wake publication             |
| `fm-watch-keeper.sh`     | Respawn the daemon watcher inside the detached tmux fallback session                  |
| `fm-delivery.sh`         | This home's external wake-delivery listener: observe the durable queue, submit into the session pane, retry until a turn drains it |
| `fm-delivery-lib.sh`     | Delivery records, listener health, the primary-endpoint record, and the one-line delivery verdict |
| `fm-delivery-service.sh` | Install, converge, restart, and report this home's delivery listener; publish the session endpoint |
| `fm-delivery-keeper.sh`  | tmux keeper tier for the delivery listener where systemd --user is unusable          |
| `fm-pane-activity-lib.sh` | The shared pre-typing pane reads every process that types into the captain's pane takes |
| `fm-watch.sh`            | Singleton-safe daemon watcher that absorbs benign wakes and durably queues actionable ones |
| `fm-context-lib.sh`      | The context-ceiling predicates and branch classification - size, quiet boundary, captain presence, receipt freshness, re-entry path, blocked, ask, reset, and unenforced - shared by the watcher and the reset tool (docs/context-reset.md) |
| `fm-stow-receipt.sh`     | Record that this session's durable knowledge was filed, bound to the transcript position it was filed at |
| `fm-context-reset.sh`    | Verify the receipt, the quiet boundary, and the way back in, then clear this session; refuses loudly and discards nothing on any failure. `--captain-approved` is the path for a reset the captain asked for, where the approval replaces the idle inference and the receipt must postdate it (docs/context-reset.md) |
| `fm-tg-recv-arm.sh`      | Verified home-scoped direct Telegram receiver arm wrapper with attach-or-start behavior |
| `fm-tg-send.sh`          | Send the captain one message, or one named file, on the direct Telegram channel, refusing loudly rather than reporting a delivery nobody got |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-supervision-lib.sh`  | Shared in-flight-work and watcher-beacon status                                       |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-transition-lib.sh`   | Shared backend-neutral agent-state transition record and supervision policy          |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-currency-base-lib.sh` | Shared resolution and validation of the two upstream-check comparison bases          |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes within a bounded echo that preserves rather than discards what it withholds, emit bounded best-effort status-event annotations, then assert watcher liveness |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher/away-daemon identity/health helpers |
| `fm-journal.sh`          | Read the append-only event journal in arrival order, and report the horizon and gaps the stream cannot account for (docs/event-journal.md) |
| `fm-journal-lib.sh`      | Append-only notification journal internals; its header owns the record contract (`docs/event-journal.md` gives rationale) |
| `fm-bosun.sh`            | Run, watch, and read back the observer-only bosun: it judges journal events and records every judgement, and it changes nothing about what surfaces (docs/bosun-observer.md) |
| `fm-bosun-lib.sh`        | The bosun's verdict record contract, its escalation bias on every failure to judge, and the health record that separates a quiet bosun from a stalled one |
| `fm-bosun-judge-codex.sh` | The bosun's default judge: one event in on stdin, one schema-constrained JSON verdict out. A provisional model behind a swappable seam, not the survey's answer |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-external-wait wake classification vocabulary    |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for target resolution, own-window startup repair, busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll and provenance publication |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-merge.sh`         | Refuse a placeholder PR title, and separately a title it could not read, record PR metadata, then merge a task's canonical full GitHub URL and have the forge delete the merged head branch |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-harness-pid-lib.sh`  | Shared harness-process identity for every per-session record, from a tool call's ancestry |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash newly offered mentions and emit their once-only wake |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
