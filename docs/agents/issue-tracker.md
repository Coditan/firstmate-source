# Issue tracker

Where work for this repository is queued, and how the GitHub issue surface relates to it.

## Who reads this file

Two installed engineering skills read this configuration, which is worth stating because it is more than the surface's reputation suggests and because it decides what this file has to answer.

- `code-review` reads it by path, to resolve issue references such as `#123` or `Closes #45` found in commit messages.
- `triage` reads it as "the tracker config", without naming the path: it takes from here whether external pull requests count as a request surface, and how to resolve a bare `#42` to an issue or a pull request.

Both questions are answered below, so neither skill has to guess.
Re-take this reading rather than trusting it; it was taken on one seat on 2026-08-22, against `mattpocock-skills` 1.2.3, by grepping the installed skill sources for this path and for the tracker config.

## The queue is the durable backlog

Work for this repository is queued in the durable backlog, not in an issue tracker.
`AGENTS.md` section 10 owns that contract in full, including the record kinds, the hold vocabulary, retention, and the command surface.
This file does not restate any of it; read section 10, and `tasks-axi --help` for routine syntax.

Nothing in this fleet dispatches work from a GitHub issue.
A skill that says "publish to the issue tracker" is asking for a backlog item, and one that says "fetch the relevant ticket" is asking for a backlog record.

## GitHub issues are a real surface, and they are not the queue

Both halves matter, and a reader who takes only the first will look in the wrong place.

Issues are genuinely used.
The fleet acts under a single GitHub identity, so this is measurable fleet-wide rather than from one seat: on 2026-08-22, `gh-axi api 'search/issues?q=author:<the fleet's GitHub identity>+is:issue'` returned eighteen issues, filed both against projects this fleet does not own and against several it does.
They carry findings, feature requests, and defect reports addressed to a project's own maintainers.
Inbound traffic on those threads reaches the fleet through the notification watch rather than by anyone polling an issue list; `bin/fm-github-inbox.sh` owns that mechanism and `docs/github-inbox.md` records the measurements behind it.

None of that makes an issue a work item here.
An issue is a message to a project's maintainers; a backlog record is an instruction to this fleet.
Filing an issue therefore never queues work, and closing one never completes any.
When an issue does imply work for this fleet, the work is filed in the backlog and the issue is left as what it is.

## Resolving a bare number

On this repository the issue surface is empty: `gh-axi issue list --state all` returned zero on 2026-08-22.
A bare `#<n>` in a commit message here is therefore a pull request, not an issue, because GitHub shares one number space between the two.
Resolve such a reference with `gh-axi pr view <n>` first, and treat an issue lookup as the fallback rather than the default.

Re-take that reading rather than trusting the date; the command is given so that it can be re-run.

## Pull requests as a request surface: no

This is the flag `triage` reads, and it is deliberately off.

The temptation to turn it on is real, because pull requests genuinely are this repository's live inbound surface while its issue list is empty.
That is exactly why it stays off.
Pulling pull requests into a triage queue would make a second queue beside the backlog, holding the same work under a different vocabulary, and the two would disagree the first time only one was updated.
A pull request that implies work for this fleet is filed in the backlog like anything else.

## Triage labels

There is deliberately no `docs/agents/triage-labels.md` in this repository, and the `## Agent skills` block in `AGENTS.md` names no label vocabulary.

The reason is not that the skill is missing.
On the seat that authored this file the `triage` skill was installed and user-invocable, and as recorded above it is one of this file's two readers.
An earlier reading of this repository called it uninstalled, which was wrong: it ships in the plugin and carries `disable-model-invocation: true`, so it is absent from a model-facing skill listing while being perfectly present.
That distinction is recorded here because the mistake is easy to repeat and produced a plausible reason for the right outcome.

The actual reason is the same one that governs the flag above.
The five canonical triage labels describe states of an issue moving through an issue tracker.
This repository's queue is the backlog, whose own record kinds and hold vocabulary are owned by `AGENTS.md` section 10 and spelled by `bin/fm-chart-kinds-lib.sh`.
Adding a second vocabulary here would create the second queue this file exists to prevent.

Whether `triage` is reachable is in any case a per-seat reading, and this file travels to every vessel, so no such reading is recorded as a standing fact.
A vessel that wants to run triage against a real GitHub issue queue should configure it in the repository that has one, and should not point it at the backlog.
