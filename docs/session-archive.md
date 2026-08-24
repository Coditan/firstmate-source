# The searchable session archive

A session that has been cleared is gone, and the backlog can only ever paraphrase what was said in it.
The session archive keeps a reduced, redacted, searchable derivative of this machine's own agent transcripts, so a decision can be recovered at the moment it was typed rather than as a later quotation of it.

The tool is shared and reaches every vessel through `bin/`.
The archive it builds is not shared and never becomes shared: it is a private derivative of one machine's material, it lives under that home's gitignored `data/`, and no vessel reads another's.

## What it is

Two stores, one per source, under `$FM_HOME/data/transcripts/`:

```
claude-redacted/    one .txt.zst per session, mirroring ~/.claude/projects
  _index.tsv        path, time span, working directory, entry count, first user message
codex-redacted/     one .txt.zst per session, mirroring ~/.codex/sessions
  _index.tsv        path, time span, working directory, entry count, first user message
```

Each session file is one zstd-compressed plain-text document.
`_index.tsv` is the one uncompressed file in a store, because it is read by an `awk` narrowing pass rather than by the content scan.

Per session, one plain-text document - compressed on disk, and read back in full by every search - holding a header, then:

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

**A full content scan is the index.**
The archive is UTF-8 text laid out one file per session, and a scan of the whole store was measured at 1.50 to 1.54 s for the file list, and 2.31 to 2.64 s with context, over the compressed 48.9 MB on 2026-08-19, so no inverted index exists and none should be added.
An index is a component that can be silently out of date, which is exactly the failure this archive was built against.
Compression does not reintroduce that failure and is why it was worth doing: the compressed file is the content, not a summary of it, and a decompression that goes wrong is an error rather than a wrong answer.
`_index.tsv` is not a search index: it narrows the file set before the scan runs, and only when `--since` or `--cwd` asks it to.

**Plain `grep -r` no longer reads this archive.**
It matches nothing in a compressed session and exits reporting no matches, over an archive that is full - the same silent emptiness the whole design refuses, arriving through the documentation instead of through the reader.
It is worse than wholly blind: `_index.tsv` is the one plain file left, so a phrase that happens to sit in its first-user-message column still matches, and the blindness looks selective rather than total.
Anyone who wants the raw tools rather than the wrapper reads a session exactly as the wrapper does:

```sh
zstd -dcq some-session.txt.zst | grep 'pattern'
```

### The tools a search requires

`zstd`, `grep` and `xargs`, on `PATH`.
That is the whole list, and the wrapper reports a missing one as a missing tool rather than as a search that found nothing.
No override names any of them, because a knob governing only part of the process twice passed its own prerequisite check before the scan read nothing.

The list is short deliberately.
An earlier version scanned with ripgrep and `-z`; it was withdrawn on 2026-08-19 on measurement rather than taste.
Ripgrep behaved differently on this seat and on the CI runner - which flags the build accepted, whether it could decompress at all - and twice reported an empty result over a full archive.
A search tool that answers differently depending on the machine it runs on is the same silent disagreement this archive exists to refuse, so the dependency was removed rather than pinned to a version.
`zstd` is already required to build the store, and `grep` and `xargs` are on any machine that can run this repository's tests at all.

**Both search paths read every session through to the end.**
The decompressor's exit status is therefore always meaningful, and any non-zero status is a genuine failure to read the store.
Requiring the reader to exit 0 while the scan stopped at the first match returned 0 matching sessions where 75 were expected over a full archive, while accepting only signal 141 made a search that matched every session exit 2 on a machine whose zstd reports a closed pipe differently.
Reading every session through is what makes a corrupt store file detectable on both paths, including one whose valid prefix contains the match.
`tests/fm-transcript-archive.test.sh` proves that invariant with a compressed session whose matching valid prefix is followed by a truncated frame.

## Rebuild

```sh
bin/fm-transcript-refresh.sh
```

It rebuilds each raw transcript store present on the vessel and then re-runs the detector against each resulting derivative - reading it back through the decompressor, as a search does - and requires zero hits.
There is no incremental path and no build state, because a full rebuild of a two-thousand-session store costs about two minutes and a build state is one more thing that can be quietly wrong.
The archive retains sessions the raw store no longer has: a rebuild rewrites every session it can still read and removes nothing, so a session deleted, rotated away, or renamed under `~/.claude` or `~/.codex` keeps its reduced copy in the archive.
This is intended rather than a defect, because the archive exists precisely so that what was said survives the clearing of the session that said it, and outliving the raw store is the point.
The archive therefore does not mirror a deletion, so removing material from the archive is a deliberate separate act and never a side effect of a rebuild.
`_index.tsv` is regenerated from the sessions the rebuild could still read, so a retained session whose raw source is gone stays findable by a plain unfiltered search but is not listed in the index, and a search narrowed by `--since` or `--cwd` will therefore not reach it.
The raw stores are read-only inputs; nothing under `~/.claude` or `~/.codex` is written, moved, or removed.
A raw store that does not exist on this vessel is reported and skipped, never treated as a store that happened to be empty.

## Compression, and why it does not cost the property above

Each session is written as one zstd file at level 3, which took this seat's store from 271.2 MB to 52.1 MB on 2026-08-18.
`zstd` is a hard requirement of a rebuild rather than a preference: a run that cannot compress refuses before writing anything, because a store that is half compressed and half plain is a store whose answers depend on which half a question lands in.
`FM_ZSTD` may name the compressor used specifically for building and verifying the store; it does not apply to searching, and it exists because it is the only way to build a store on a machine where `zstd` is not on `PATH`.
That split is a known condition rather than an oversight: a store written by an overridden compressor is read back by the `zstd` the search finds on `PATH`, so the two have to be able to read each other, which ordinary zstd builds do and something that is not zstd-compatible does not.
A rebuild also compresses whatever plain session files it finds already in the store and drops the plain copies it has just superseded, so an archive built before compression converges on the first refresh instead of being stranded, and a retained session the rebuild cannot reach is compressed where it lies rather than left behind.
The level is a knob, `--level`, and the measurement behind the default is below.

The store stays honest under compression for one reason: the compressed file is the content rather than a summary of it, so nothing exists that could disagree with it, and a decompression that goes wrong is an error rather than a wrong answer.
A verification that cannot read a store file says so and fails, instead of counting a file nobody read as a file that came back clean.

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
                       raw          derivative      on disk    ratio    redactions
Claude              1007.6 MB        116.6 MB        27.2 MB    8.6:1        73
Codex                418.7 MB        143.6 MB        21.7 MB    2.9:1        37
combined            1426.3 MB        260.2 MB        48.9 MB    5.5:1       110
sessions                                2273
full rebuild + verification                          ~129 s
full-content search, file list / with context       1.50 - 1.54 s / 2.31 - 2.64 s
verification residual hits                              0
```

`derivative` is the text a search reads; `on disk` is what the store costs after compression.
The whole archive directory, including the two indexes, went from 271.2 MB to 52.1 MB in the migration of 2026-08-18, and no session was lost to it: of the 2236 sessions present beforehand, 2144 came back byte-identical and 92 came back longer because the session had continued since the previous build.

### Choosing the compression level

Measured the same day, on the same seat's real store rather than on a sample, each a full rebuild with verification:

```
                    rebuild + verify      store on disk      against plain
plain (before)              89.8 s            273.6 MB               1.0x
zstd -3                    119.4 s             52.1 MB               5.25x
zstd -9                    159.6 s             48.7 MB               5.62x
```

Level 3 is the default because level 9 spends 40 more seconds of every rebuild to save 3.4 MB, which is 1.2 percent of what was already saved.
The compression ratio is material-dependent: these are readings from one seat's transcripts, not properties of zstd.
Search cost is not part of this tradeoff - zstd decompresses at roughly the same speed whatever level wrote the file - so the level buys rebuild time against disk and nothing else.

The reduction ratio is material-dependent and is not a property of the tool: the same design measured 56:1 on a seat whose sessions averaged 17 MB, against 0.63 MB here.
`--fold-injected` folds Codex's machine-injected user messages down to their marker and their tail, taking the Codex store from 142.2 MB to 44.1 MB.
It is off by default, and the reason is the finding rather than the size: folding dropped 24 of the 37 redaction findings, including 16 of the 22 private-key blocks, because those sat inside the folded region.
The folded archive is not cleaner - less of it was ever looked at.

## A search test that passed where it was written, 2026-08-24, one seat

A peer vessel's run of `tests/fm-transcript-archive.test.sh` reported `not ok - a --files-only sort failure must exit 2, got 0`, twice, while the same test on this seat passed every assertion.
The case builds a restricted PATH, replaces `sort` on it with a stand-in that fails, and requires the search to exit 2.

The tool was not the fault, and the difference was not a missing tool either.
Dropping each of the fifteen tools the case links, one at a time, produced exit 1, 2 or 127 on this seat and never 0, so a case that returns before it sorts cannot produce the reported symptom.
Replacing `sort` with a stand-in that fails at once, one that consumes its input and then fails, and one that emits output and then fails each produced exit 2 on both search paths.
`bin/fm-transcript-search.sh` reads the sort stage's status on both paths and always did.

What produced the 0 was the fixture, which installed a working `sort` and then asserted an exit status as though it had not.
The stand-in was a symlink to whatever `type -P false` resolved to, and a multi-call binary picks its applet from `argv[0]`.
`argv[0]` there is `sort`, not the name of the file the link points at, so on a seat whose `/usr/bin/false` is a BusyBox or toybox symlink the case installs BusyBox's own `sort`.
Simulated here by pointing `false` at this seat's BusyBox and changing nothing else, the pre-change test file reproduced the peer's line verbatim, `not ok - a --files-only sort failure must exit 2, got 0`, and the search's own output showed it had sorted its result and matched.
An exported shell function named `sort`, and a `BASH_ENV` that restores a full PATH, were measured to produce the same 0 by different routes.

A second defect sat behind the first, and it held even where the case passed.
A stand-in that exits before reading its input closes the pipe on the stage above it, which then fails too: measured as `PIPESTATUS` `1 1 1`, against `0 1 1` for a stand-in that drains first.
The refusal was therefore satisfied by the upstream status, and the sort stage's own status was never read by the assertion that is named for it.
A tool mutated to ignore the sort stage's status passed the pre-change case and fails the post-change one.

The case now refuses instead of asserting: it names a tool this seat does not have rather than silently building a different world, writes its stand-in out instead of linking to another program's name, proves the stand-in fails and runs before the assertion leans on it, and drains so that exactly one stage in the pipeline is non-zero.

What is not established from here: the peer seat's own `/usr/bin/false` was never inspected, so BusyBox is a sufficient mechanism for the reported line and not a measured cause of it.
The reproduction above says the fixture can produce that exact line with the tool untouched; it does not say that is what happened there.
