# Domain docs

This repository uses a single-context domain documentation model.
Use `AGENTS.md` as the project glossary and instruction surface, and load `domain-modeling` whenever a term needs sharpening or a domain claim needs recording.
Do not create a parallel `CONTEXT.md` or `docs/adr/` tree for Matt Pocock skills unless the repository's own instruction model changes first.

The generated Matt Pocock skills configuration remains under `docs/agents/`.
That placement is deliberate even though this repository also has `.agents/skills/`: upstream issue 937 records that `code-review` still reads `docs/agents/issue-tracker.md` literally while other skills follow the pointer block.
The proposed upstream fix was noted at `micheltriana:skills:fix/code-review-resolve-tracker-doc-via-pointer`.
Revisit this placement after that fix lands; moving it later is a directory rename plus the pointers in `AGENTS.md`.
