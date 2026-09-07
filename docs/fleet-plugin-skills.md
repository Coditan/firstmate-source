# The plugin skills the fleet expects every seat to carry

## Why this exists

Skills under `.agents/skills/` reach every vessel on their own.
They are vendored material carried by the fleet pin, which is how the omega skill reached six vessels within an hour of a merge with nobody installing anything.

Third-party plugin skills do not travel that way.
They are installed per seat by the harness, into a directory outside every repository this fleet controls.
Until `bin/fm-skills-lock.sh` existed, nothing recorded that a seat was supposed to have one, nothing checked whether it did, and a seat that was missing one lost the skills that depend on it in silence.
That is not hypothetical: `.agents/skills/codebase-sweep`, `.agents/skills/design-it-twice`, and `.agents/skills/scout-research` all reach for `mattpocock-skills`, and on a seat without it they find nothing and say nothing.

It is a mechanism rather than an instruction on purpose.
A sentence telling a seat to install something is carried by whoever remembers to read it, and this fleet has already measured what that is worth.

## The three parts

| Part | Owner | When it runs |
| --- | --- | --- |
| What the fleet expects | the `plugins` object in `skills-lock.json` | read by every part below |
| Installing what is missing | `bin/fm-skills-lock.sh`, invoked from `bin/fm-bootstrap.sh` | every session start, cadence-gated to once a day |
| Reporting a seat that is short | the `plugin:<id>` reading in `bin/fm-currency-round.sh` | the daily currency round, between sessions |

`bin/fm-skills-lock.sh`'s header owns the exact modes, flags, states, and environment.
`skills-lock.json` records only what to install and where it comes from; no third party's skill content is vendored here.

## Can a seat's installed plugin set be read reliably? The measurement

This was the open question the work started from, and the answer is yes, but not by the route it looked like.

Measured on 2026-09-07 on the `coditan-vessel` seat:

```
$ claude plugin list --json
[
  {
    "id": "mattpocock-skills@claude-plugins-official",
    "version": "1.2.3",
    "scope": "user",
    "enabled": true,
    "installPath": "/home/coditan/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3",
    "installedAt": "2026-08-04T04:16:11.053Z",
    "lastUpdated": "2026-08-07T02:57:41.016Z"
  }
]
```

```
$ claude plugin list --help
Usage: claude plugin list [options]
List installed plugins
Options:
  --available  Include available plugins from marketplaces (requires --json)
  --json       Output as JSON
```

The versioned cache directory is real, and it is exactly the fragile thing the question suspected: `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>` embeds both a marketplace name and a version, and it is an internal detail of a tool this fleet does not own.
`.agents/skills/codebase-sweep/SKILL.md` already warns against constructing that path from a version number.
But the cache path is not the only route.
`claude plugin list --json` is a documented command with a documented flag, and it answers the question directly, so that is what the check reads.
`~/.claude/plugins/installed_plugins.json` was also measured and carries the same facts behind a declared `"version": 2` schema; it is the store the command reads, and it is not read directly here, because a documented command is a narrower thing to depend on than a file format.

Reliability of the reading is therefore not assumed, and the check keeps three separate outcomes so its silence can be trusted:

- **skipped** - no `claude` on this seat's `PATH`, so it has no plugin mechanism and cannot be short of a plugin skill.
- **unmeasured** - `claude` is here and its plugin list could not be read or did not parse, so this seat's set is unknown rather than empty.
- **missing / disabled / version-differs** - the list was read and it actually says so.

Only the third kind is ever acted on, and `tests/fm-skills-lock.test.sh` drives all three.

## Why a version is pinned and why it is not enforced by installing one

`claude plugin install` takes no version argument, so the install path cannot target a pin even if it wanted to.
That is not a gap the lock works around, because raising the pin is a decision rather than a repair.

The pinned version of `mattpocock-skills` is `1.2.3`, and `skills-lock.json`'s `versionBasis` field states the basis in the file itself rather than here.
In short: it is the release every tracked skill in this repository that depends on the plugin was derived from and verified against, recorded in `docs/scout-research-provenance.md`, `docs/design-it-twice-provenance.md`, `docs/agents/domain.md`, `docs/agents/issue-tracker.md`, and `docs/grossreinschiff.md`.
It is not the version this seat happened to have; that it is also what this seat runs is a coincidence of the two being kept in step by those provenance reads.
The official marketplace has since moved its source pointer for this plugin to sha `6654f6b60cd9d5be8b54c6fafe44346dabeb3b76`, read on 2026-09-07, so a seat that installs it fresh today will get something newer than the pin and be reported as differing.
That report is the intended behaviour: it says out loud that this repository's derived skills were checked against `1.2.3` and nobody has re-checked them against what the marketplace now serves.

## Licence and provenance

Nothing of the plugin's content is copied into this repository, so this file is a mechanism note and not a provenance notice.
The provenance notices for the material this fleet actually derived from `mattpocock/skills` are `docs/scout-research-provenance.md`, `docs/design-it-twice-provenance.md`, and `docs/codebase-sweep-provenance.md`, and each carries its own MIT notice.
`docs/grossreinschiff.md` records the 2026-08-17 sweep that confirmed the installed plugin carries its own MIT `LICENSE`.

## What this does not cover

It measures and converges **this seat only**.
A silent round here never means the fleet carries the expected set: it means this seat does.
Nothing in this mechanism reads, installs into, or reports on another vessel.
