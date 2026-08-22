# Issue tracker

Where work for this repository is queued, and how the GitHub issue surface relates to it.
This file exists because some installed engineering skills expect it; `code-review` reads it by path to resolve issue references found in commit messages.

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

On this repository specifically, the surface is empty: `gh-axi issue list --state all` returned zero on 2026-08-22.
A bare `#<n>` in a commit message here is therefore a pull request, not an issue, because GitHub shares one number space between the two.
Resolve such a reference with `gh-axi pr view <n>` first, and treat an issue lookup as the fallback rather than the default.

Re-take both readings rather than trusting the dates above; the commands are given so that they can be re-run.

## Triage labels

There is deliberately no `docs/agents/triage-labels.md` in this repository, and the `## Agent skills` block in `AGENTS.md` names no label vocabulary.

The five canonical triage labels describe states of an issue moving through an issue tracker.
This repository's queue is the backlog, whose own record kinds and hold vocabulary are owned by `AGENTS.md` section 10 and spelled by `bin/fm-chart-kinds-lib.sh`.
Adding a second vocabulary here would create exactly the second queue the section above exists to prevent, and the two would disagree the first time only one was edited.

Whether the `triage` skill is reachable is a per-seat reading, and this file travels to every vessel, so no such reading is recorded here.
It is worth stating plainly that the absence of the labels file is not evidence that the skill is missing: on the seat that authored this file the skill was present and user-invocable.
A vessel that wants to run triage against a real GitHub issue queue should configure it in the repository that has one, and should not point it at the backlog.
