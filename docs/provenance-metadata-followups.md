# Provenance metadata follow-ups, 2026-08-18

This record closes the metadata gaps found by `data/fm-wayfinder-provenance-sweep/report.md`, without changing any licence.
It records only what local artefacts or named upstream pointers establish.
Where a local terms file was not found, the row says so instead of naming an inferred licence.

## `/no-mistakes` skill wrapper

Local record now exists, deliberately pointing at the no-mistakes tool repository and licence source the skill wraps.
The installed skill directory contains only `SKILL.md`, so it carries no adjacent licence file.
The skill invokes the `no-mistakes` CLI, and the sweep measured the related tool source as `https://github.com/kunchenguid/no-mistakes` with MIT licence evidence at that repository's `LICENSE`.
This record is a pointer for the skill wrapper; it does not change or re-license the local binary copy.

## Codex system `review-agent`

Local record now exists; local licence or terms evidence not found.
`/home/crew/.codex/skills/.system/review-agent/` contains `SKILL.md` and `agents/openai.yaml`, but no local licence or terms file was found in that skill directory.
The named source pointer is the installed Codex/OpenAI system-skill bundle under `/home/crew/.codex/skills/.system/`, whose root contains `.codex-system-skills.marker` but no local bundle-level licence or terms file.
This record does not infer a separate licence for the individual skill.

## Codex system `plugin-creator`

Local record now exists; local licence or terms evidence not found.
`/home/crew/.codex/skills/.system/plugin-creator/` contains `SKILL.md`, scripts, references, agents, and assets, but no local licence or terms file was found in that skill directory.
The named source pointer is the installed Codex/OpenAI system-skill bundle under `/home/crew/.codex/skills/.system/`, whose root contains `.codex-system-skills.marker` but no local bundle-level licence or terms file.
This record does not infer a separate licence for the individual skill.

## Codex plugin `plugin-management`

Local record now exists; local proprietary terms file not found.
`/home/crew/.codex/plugins/cache/openai-curated-remote/plugin-management/0.1.0/.codex-plugin/plugin.json` names author OpenAI, repository `https://github.com/openai/openai/tree/master/chatgpt/oai-maintained-plugins/plugins/plugin-management`, licence label `Proprietary`, terms URL `https://openai.com/policies/row-terms-of-use/`, and privacy URL `https://openai.com/policies/row-privacy-policy/`.
No adjacent licence, terms, or notice file was found in the local Codex cache.

## Cached Codex plugin `openai-templates`

Local record now exists; local proprietary terms file not found.
`/home/crew/.codex/plugins/cache/openai-curated-remote/openai-templates/0.1.1/.codex-plugin/plugin.json` names author OpenAI, repository `https://github.com/openai/oai-maintained-plugins/tree/main/plugins/openai-templates`, licence label `Proprietary`, terms URL `https://openai.com/policies/row-terms-of-use/`, and privacy URL `https://openai.com/policies/row-privacy-policy/`.
No adjacent licence, terms, or notice file was found in the local Codex cache.

## Local AXI package `gnhf`

Local record now exists for the installed package metadata gap.
`/home/crew/firstmate/.local/axi/lib/node_modules/gnhf/package.json` names repository `https://github.com/kunchenguid/gnhf` and version `0.1.44`, includes `LICENSE` in its published files, and omits a `license` field.
`/home/crew/firstmate/.local/axi/lib/node_modules/gnhf/LICENSE` is present.
The installed package metadata still omits the field; this record notes the local licence evidence without modifying the package copy.

## Herdr licence boundary

The Herdr licence boundary belongs to [`docs/herdr-backend.md`](herdr-backend.md), because that document owns Firstmate's Herdr install, runtime, and verification evidence.
This follow-up records only that the 2026-08-17 sweep required that boundary to distinguish the pinned release evidence from current upstream `master`.
