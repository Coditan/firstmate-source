# Graphify

`AGENTS.md` carries the standing facts: project graphs are read-only to firstmate, `graphify update .` is never run inside `projects/`, and this repo has no graph by construction.
This document owns the rest, and is the load target for `/graphify`.

## The staleness test a graph answer must pass

Before trusting any graph answer, compare the graph's build record with that project's current `HEAD`.
Treat it as current only when `graphify-out/graph.json` records `built_at_commit` equal to `git rev-parse HEAD`; if the field is missing or differs, including an ancestor behind `HEAD`, verify from source instead.

## Which command to reach for

When a current graph exists, prefer `graphify query "<question>"` for codebase questions, `graphify path "<A>" "<B>"` for relationships, and `graphify explain "<concept>"` for focused concepts.
Use `graphify-out/wiki/index.md` for broad navigation when it exists, and read `graphify-out/GRAPH_REPORT.md` only for architecture review or when query, path, and explain do not surface enough context.

## Who may rebuild a graph

Firstmate may read project graphs but must not run `graphify update .` inside `projects/`.
A crewmate may run `graphify update .` only inside its own isolated task worktree, as part of a change it is already authorized to make there.

On `/graphify`, use these rules directly; no graphify skill is installed here.
