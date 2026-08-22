# Issue tracker

Firstmate uses the fleet backlog as its issue tracker; GitHub carries pull requests only.
The durable queue is `data/backlog.md`, reached through `tasks-axi` when the configured backend selects it, and `AGENTS.md` section 10 owns the backlog contract.
Backlog state is per home, so work routed to a secondmate is tracked in that secondmate home's backlog.
Use `/to-backlog` to size a plan, spec, or report into work items, and use `decision-hold-lifecycle` for captain decisions.
Use `gh-axi` for GitHub pull request operations.
Because firstmate never writes to a project, work for a project becomes a fleet backlog item rather than an issue filed in that project's repository.
