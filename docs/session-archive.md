# The searchable session archive

A session that has been cleared is gone, and the backlog can only ever paraphrase what was said in it.
The session archive keeps a reduced, redacted, searchable derivative of this machine's own agent transcripts, so a decision can be recovered at the moment it was typed rather than as a later quotation of it.

The tool is shared and reaches every vessel through `bin/`.
The archive it builds is not shared and never becomes shared: it is a private derivative of one machine's material, it lives under that home's gitignored `data/`, and no vessel reads another's.

## What it is

Two stores, one per source, under `$FM_HOME/data/transcripts/`:

```
claude-redacted/    one .txt per session, mirroring ~/.claude/projects
  _index.tsv        path, time span, working directory, entry count, first user message
codex-redacted/     one .txt per session, mirroring ~/.codex/sessions
  _index.tsv        path, time span, working directory, entry count, first user message
```

Per session, one plain-text file holding a header, then:

- every user and assistant message, verbatim
- every command issued, verbatim
- the first 400 characters of every tool result and every reasoning block

Everything else is discarded: tool output past the cap, encrypted reasoning blobs, file-history snapshots, token accounting, and queue bookkeeping.
The 400-character cap and the verbatim conversation sides are a deliberate design choice adopted from sc1's 2026-08-03 report, not an accident of implementation, and `--truncate` is the only knob on it.

## How to search it

```sh
bin/fm-transcript-search.sh 'an-identifier'                        # both stores
bin/fm-transcript-search.sh 'a phrase someone typed' -C 2          # with context
bin/fm-transcript-search.sh 'pattern' --since 2026-08-15 --cwd myproject
bin/fm-transcript-search.sh 'pattern' --files-only
```

**Grep is the index.**
The archive is UTF-8 text laid out one file per session, and a full-content scan of the whole store was measured at 0.22 s over 258 MB on 2026-08-18, so no inverted index exists and none should be added.
An index is a component that can be silently out of date, which is exactly the failure this archive was built against.
`_index.tsv` is not a search index: it narrows the file set before grep runs, and only when `--since` or `--cwd` asks it to.
Plain `grep -r` over the archive works identically for anyone who does not want the wrapper.

## Rebuild

```sh
bin/fm-transcript-refresh.sh
```

It rebuilds each raw transcript store present on the vessel and then re-runs the detector against each resulting derivative, requiring zero hits.
There is no incremental path and no build state, because a full rebuild of a two-thousand-session store costs about 95 s and a build state is one more thing that can be quietly wrong.
The archive retains sessions the raw store no longer has: a rebuild rewrites every session it can still read and removes nothing, so a session deleted, rotated away, or renamed under `~/.claude` or `~/.codex` keeps its reduced copy in the archive.
This is intended rather than a defect, because the archive exists precisely so that what was said survives the clearing of the session that said it, and outliving the raw store is the point.
The archive therefore does not mirror a deletion, so removing material from the archive is a deliberate separate act and never a side effect of a rebuild.
`_index.tsv` is regenerated from the sessions the rebuild could still read, so a retained session whose raw source is gone stays findable by a plain unfiltered search but is not listed in the index, and a search narrowed by `--since` or `--cwd` will therefore not reach it.
The raw stores are read-only inputs; nothing under `~/.claude` or `~/.codex` is written, moved, or removed.
A raw store that does not exist on this vessel is reported and skipped, never treated as a store that happened to be empty.

## The honest bound, which travels with every claim made from this archive

> The derivative is verified: the same detector re-run against the output returns zero hits.
> **That statement covers the derivative and nothing else.**
> **What the reduction discarded was never examined for credentials at all.**
> And the redaction is exactly as good as `bin/fm-transcript-patterns/patterns.txt` and not one bit better: what the detector never knew, it never removed.

A verification that finds no files to verify refuses rather than returning zero, because zero hits over zero files is a reading the detector could not take and not an all-clear.
This is not a caveat to be dropped when the sentence gets long.
The bound is carried in three places on purpose - in the header of every session file the tool emits, in the `README.md` the refresh writes into the archive directory, and here - because a report is read once and an archive is read for years.

## Two readers, selected explicitly

The two source shapes share no key.
A Claude-shaped reader reads a Codex rollout as zero entries and raises nothing at all, which looks exactly like a session that had nothing in it; measured on 2026-08-18, 32.9 MB of real Codex material through a Claude reader produced an empty file with no error and no warning.
So `--source` is explicit, and four fail-closed refusal paths prevent missing input or unreadable material from looking like a clean archive:

- The run pre-flights every input file for its record shape and refuses, naming the paths, before writing anything when the shape disagrees with `--source`.
- A run that finds no input files at all refuses rather than writing an archive that looks built.
- A run that reads files but recovers zero entries from all of them exits non-zero and says so.
- A `--verify-only` run that finds no derivative files refuses rather than reporting a zero-hit all-clear.

## The pattern file must not match itself

Every literal in `bin/fm-transcript-patterns/patterns.txt` is spelled with a self-breaking character class, so the file does not match its own patterns.
The reason is measured, not theoretical: a detector whose patterns appear in plain text gets those patterns written into the next session transcript, and every later scan then inflates on its own tooling.
sc1's rule - patterns live in a file and are never typed on a command line - is necessary but not sufficient, because authoring the file is itself a recorded command.

Two consequences bind anyone who touches this tool:

1. Preserve the self-breaking spelling exactly.
   `tests/fm-transcript-archive.test.sh` scans the pattern file against itself, and the tool and its own tests against the pattern file, and requires zero in every direction.
2. Build test fixtures the same self-breaking way.
   The original build left five real redactions in its own session from fixtures typed in plain form and named that as a known residue; the test suite exists so that residue is not reproduced.

## What this does not cover

- `~/.codex/logs_2.sqlite` - Codex's own internal log, larger than the Codex transcripts, never examined.
- `~/.claude/history.jsonl` and `~/.codex/history.jsonl` - flat prompt history, small, not included.
- `~/.claude/file-history/` - file snapshots, not conversation.
- Anything before the raw stores begin on a given machine.
- Every other vessel: each home archives its own material only.

## Measurements, 2026-08-18, one seat

Recorded with their date because they are readings, not properties.

```
                       raw          derivative      ratio    redactions
Claude              1001.5 MB        115.6 MB       8.7:1        73
Codex                413.5 MB        142.2 MB       2.9:1        37
combined            1415.0 MB        257.8 MB       5.5:1       110
sessions                                2236
full rebuild + verification              ~95 s
full-content search over the store       0.22 s
verification residual hits                  0
```

The ratio is material-dependent and is not a property of the tool: the same design measured 56:1 on a seat whose sessions averaged 17 MB, against 0.63 MB here.
`--fold-injected` folds Codex's machine-injected user messages down to their marker and their tail, taking the Codex store from 142.2 MB to 44.1 MB.
It is off by default, and the reason is the finding rather than the size: folding dropped 24 of the 37 redaction findings, including 16 of the 22 private-key blocks, because those sat inside the folded region.
The folded archive is not cleaner - less of it was ever looked at.
