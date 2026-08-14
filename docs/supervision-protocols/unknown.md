Mode: external wake delivery, unrecognized primary harness.

This session holds no wake-delivery object of any kind, and that part is not harness-specific: the listener that turns a queued wake into a turn is a service outside every harness, supervised the way the watcher loop is.
`docs/wake-delivery.md` owns the contract.

1. A wake arrives as a message in your composer carrying the firstmate operational marker and saying records are pending.
   On it, run `bin/fm-wake-drain.sh` first, before reading anything else and before composing any reply, then handle what it returns.
2. Do not arm anything: no re-armed wait, no background job, no bounded foreground wait.
3. Ask `bin/fm-delivery-service.sh status` whenever you need to know whether delivery is working; never infer it from an empty drain.
4. What is genuinely unverified on this harness is whether the listener can read and type into its composer at all.
   If wakes are not arriving while `status` reports `delivering`, that is the gap: record what you measured in `docs/wake-delivery.md` before promoting this harness to a named snippet.
5. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
