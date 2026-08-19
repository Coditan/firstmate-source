# AXI skill provenance: installed from `kunchenguid/axi`

`.agents/skills/axi/SKILL.md` is the **official AXI skill**, by **Kun Chen**, from **[`kunchenguid/axi`](https://github.com/kunchenguid/axi)**, under the **MIT licence**.
It is not an internal invention and it is not an adaptation: it is a verbatim copy.

That upstream is the same one firstmate itself comes from - `CONTRIBUTING.md` names `kunchenguid/firstmate` as this repository's parent - so this is one ecosystem rather than an outside dependency.
It is still handled as third-party material below, because sharing an author grants no licence relief and an unattributed copy is unattributed either way.

MIT permits exactly what was done here - use and redistribute - and asks one thing in return: the copyright notice and the permission notice travel with the work.
`.agents/skills/axi/LICENSE` carries them alongside the copy, and this page carries them again below, and both land in the same commit as the skill, so the notice is never absent from a tree that contains the work.
That ordering is deliberate: an earlier adoption from a different upstream shipped without attribution and had to be corrected afterwards (`docs/sea-chart-provenance.md`).

## Why it is here at all

This fleet runs six AXI tools and twice in one day planned to build one that already existed.
The remedy that was first proposed was a fleet-written skill describing the AXI contract.
That was the wrong remedy: an official skill already exists, it is 273 lines working all ten principles with examples, and `principles.yaml` upstream states outright that the full specification of each principle lives in it.
A second description of the same contract would have been a copy that drifts.

So the contract is installed rather than restated, and this fleet's own additions - which the specification does not cover - live separately in `.agents/skills/axi-tool-intake/`.
That skill carries no design guidance by construction, and `tests/fm-axi-tool-intake.test.sh` enforces the separation in both directions.

## What was installed

| | |
| --- | --- |
| Source | `kunchenguid/axi`, skill path `.agents/skills/axi/SKILL.md` |
| Install command | `npx skills add kunchenguid/axi`, run 2026-08-19 |
| Upstream commit read | `408a653` (2026-08-16), the repository head at fetch time on 2026-08-19 |
| Licence | MIT, `LICENSE` at that repository's root, copied to `.agents/skills/axi/LICENSE` |
| Content | Byte-identical to upstream; `sha256` `59f62cd5c6eff01516cb3fcd6b1fce1e097f92df4eee2f444183b5039d20aef2` |
| Manifest | `skills-lock.json` at this repository's root, written by the installer |

The installer wrote `.agents/skills/axi/SKILL.md` and `skills-lock.json`, and it resolved the Claude Code symlink against this repository's existing tracked `.claude/skills -> ../.agents/skills` link, so it created no third copy.

An independent shallow clone of the upstream repository, read into a scratch location outside this repository, produced a SKILL.md byte-identical to the installed one.
That is what establishes the commit above as the content's origin: the installer records a source and a content hash but not a commit.

## Do not edit the installed file

`.agents/skills/axi/SKILL.md` is upstream's, and this repository's rules do not apply to it.

It uses em dashes, which this repository forbids in its own tracked Markdown, and its frontmatter carries only `name` and `description`, without the `user-invocable` and `metadata.internal` fields every skill this repository authors must declare.
**Both are correct and neither is to be fixed.**
Editing the file diverges it from `skills-lock.json`'s recorded hash, which is how the installer detects a local modification, and turns every future `npx skills` update into a conflict.

Two consequences follow, and both are enforced by `tests/fm-axi-tool-intake.test.sh`:

- The frontmatter trigger floor in `tests/fm-instruction-owners.test.sh` skips skills listed in `skills-lock.json`, because they cannot declare fields this repository invented. It still requires each of them to be reachable from `AGENTS.md` section 13, so an installed skill can never become dead weight.
- The recorded `sha256` above is asserted against the file on disk. A well-meaning local edit is otherwise invisible: the skill still loads and still works.

## Updating it

Update through the installer, never by hand: re-run `npx skills add kunchenguid/axi`, then re-record the commit, the hash, and the date in the table above in the same commit.
A provenance record that is not re-taken at update time is a record of a version that is no longer installed.

## Notice

    MIT License

    Copyright (c) 2026 Kun Chen

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
