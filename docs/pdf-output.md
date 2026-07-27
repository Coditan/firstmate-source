# Generated PDF output

Firstmate occasionally produces a PDF for the captain by printing an HTML document from a headless browser.
On 2026-07-26 one of those documents reached the captain unopenable, and this page records what was wrong, what fixed it, and what now prevents a repeat.
It is evidence, not narrative: every command and every quoted output below was run on 2026-07-27 against the file that actually failed.

`bin/fm-pdf-finish.sh` and `bin/fm-pdf-verify.sh` own the mechanics; their headers and `--help` are authoritative for flags and exit codes.
They share one option surface, parsed in `bin/fm-pdf-lib.sh`, so the two cannot drift apart when only one is corrected.

## The incident

A 27-page handover document rendered correctly on screen and would not open on the captain's phone.
Size was not the cause.
Rewriting the file through Ghostscript both repaired it and shrank it from 2,448,482 to 780,372 bytes, and the rewritten copy read cleanly through all 27 pages.

That combination - correct on screen, refused by the recipient, fixed by a rewrite - is the signature of a structurally invalid file rather than a content problem.

## The cause

The generation path printed the document with a headless browser, split it with poppler's `pdfseparate`, and reassembled it with poppler's `pdfunite`.
`pdfunite` is the step that produced an invalid file.

The trailer of the failing document:

```
trailer
<</Size 2935 /ID [(
) ] /Root 39220 0 R >>
startxref
1663372
%%EOF
```

Three numbers that cannot all be true at once:

| Value | Where it comes from | Meaning |
| ----- | ------------------- | ------- |
| `/Size 2935` | trailer dictionary | the file claims 2935 cross-reference entries |
| `0 39249` | the cross-reference table's own subsection header | the table actually declares 39249 entries |
| `39248` | highest object number written in the body | the highest object the file defines |

PDF 32000-1 section 7.5.5 requires the trailer's `/Size` to be one greater than the highest object number used in the file.
That would be 39249, which is exactly what the cross-reference table declares.
The trailer instead carries 2935, the *count* of objects written, and `/Root 39220 0 R` points at an object number that the declared size does not even reach.
`pdfunite` offsets each input file's object numbers by the previous file's size, which leaves the numbering sparse, and then writes the count where the specification requires the maximum plus one.

Ghostscript names it directly:

```
$ gs -o /dev/null -sDEVICE=nullpage -dNOPAUSE -dBATCH frota-modelo-de-operacao.pdf
Processing pages 1 through 27.
Page 1
...
Page 27

The following warnings were encountered at least once while processing this file:
	incorrect xref size

   **** This file had errors that were repaired or ignored.
   **** Please notify the author of the software that produced this
   **** file that it does not conform to Adobe's published PDF
   **** specification.
```

The browser is not at fault.
A known-good PDF pushed through the same two poppler steps acquires the identical defect, which isolates the cause to the assembly step:

```
$ pdfseparate good.pdf p-%d.pdf && pdfunite p-*.pdf united.pdf
$ gs -o /dev/null -sDEVICE=nullpage -dNOPAUSE -dBATCH united.pdf 2>&1 | grep -i conform
   **** file that it does not conform to Adobe's published PDF
```

Versions used for every command on this page: Ghostscript 10.02.1 (2023-11-01), poppler-utils 24.02.0, Linux 6.8.0.

## Why it went unnoticed

Nothing in the generation path read the file back.
The document looked right in every viewer that tolerates a broken cross-reference table, which includes most desktop viewers, and failed only in a stricter one.
A defect that is invisible at the point of production and visible only at the recipient is the expensive kind, so the fix is not a better habit but a step that cannot be skipped.

## The fix

Assembly no longer goes through `pdfunite`.
`bin/fm-pdf-finish.sh` merges and normalizes the rendered parts with Ghostscript's `pdfwrite` device, which rebuilds the document and emits a correct cross-reference table, then reads the result back with `bin/fm-pdf-verify.sh` and publishes it only if that check passes.

```
$ bin/fm-pdf-finish.sh --pages 27 handover.pdf rendered.pdf
fm-pdf-finish: published handover.pdf (27 pages, conforming)
```

The gate runs once, on the temporary file, before publication.
The success line reports that single verdict rather than re-reading the published document, so a 27-page file is interpreted once and the step's exit status stays its own: 0 means published.

Applied to the file that failed, this reproduces the original repair exactly: 2,448,482 bytes in, 780,372 bytes out, 27 pages, conforming.
The reduction comes from rebuilding the document, not from dropping content - the page count is asserted, so a repair that lost pages would fail the gate rather than ship.

Publication is atomic and conditional.
The work happens on a temporary file beside the destination and is moved into place only after the check passes, so a rejected result leaves any previous file untouched and creates no new one.

## Why the check does not trust an exit code

This is the part most likely to be undone by a well-meaning simplification, so it is recorded explicitly.

**Ghostscript exits 0 on a file it has just reported as non-conforming.**

```
$ gs -o /dev/null -sDEVICE=nullpage -dNOPAUSE -dBATCH broken.pdf >/dev/null 2>&1; echo $?
0
```

`-dPDFSTOPONERROR` and `-dPDFSTOPONWARNING` do not change this, and `-q` additionally suppresses the diagnostics while still exiting 0:

```
$ gs -q -o /dev/null -sDEVICE=nullpage -dNOPAUSE -dBATCH -dPDFSTOPONWARNING broken.pdf; echo $?
0
```

A gate written as "run Ghostscript, check `$?`" would therefore pass the exact file this whole page is about.
`bin/fm-pdf-verify.sh` takes its verdict from the reader's diagnostics instead, and treats three separate conditions as failures rather than passes:

- the reader reports a conformance problem, an error, or a structural warning;
- the reader is absent, or exits non-zero;
- the reader runs but prints no recognizable page report, which is what a stubbed, wrapped, or changed tool looks like.

The last one is the reason the script asserts that the reader announced its page range *and* interpreted the final page.
The reader's own complaint is weighed before that proof-of-work check, so a file the reader positively condemns is reported as rejected rather than as unchecked; badly truncated files draw the banner without ever reaching a page report, and they are bad files, not unexamined ones.
Silence from a checking tool is not evidence of a clean file, and a gate that passes when it could not actually check reads like an assurance while being none.

## Rejected versus could not verify

The two refusals are told apart deliberately, and both fail closed.
`REJECTED` (exit 1) means the reader's output positively named a document problem, or the gate itself found no readable, non-empty file to hand over.
A damaged file - a truncated document, or one that is not a PDF at all - is normally named by the reader and lands here, but which of the two refusals it draws follows the installed reader's wording and is deliberately not pinned (see "Proof in both directions").
`CANNOT VERIFY` (exit 3) means the check did not happen: no reader, a reader that exited non-zero without naming a document problem, or a reader that printed nothing recognizable.
That second class carries the reader's own message verbatim, so the failure is attributable.

Nothing is published either way, so the only thing at stake is whose fault it is.
Calling a broken, missing-library, OOM-killed or sandboxed reader a bad document sends someone to debug a file that was fine.
Understating genuine garbage is the safer error here, because the file is still refused.

## Proof in both directions

`tests/fm-pdf-output.test.sh` covers the contract and is proven in both directions, because a gate that only ever rejects is as useless as one that only ever accepts.
It builds its own conforming fixture with Ghostscript, then reproduces the field defect deterministically by rewriting only the trailer's `/Size` - the body is copied byte-for-byte, so the fixture needs no poppler and cannot drift.
When poppler is present it additionally asserts against genuine `pdfunite` output.

The suite asserts that a non-conforming file is rejected with the reader's own diagnosis surfaced, that a conforming file passes with its real page count, that a wrong page count is rejected and the right one accepted, that a missing reader, a silent reader, and a reader that could not run each refuse rather than pass, that a reader naming a document problem still rejects, that assembly repairs the defect while preserving every page, and that a rejected result never reaches the destination, never overwrites a previous file, and leaves no temporary artifacts.
It asserts on Ghostscript's `does not conform` banner, which is what the gate itself matches on, and not on version-specific warning wording, because no Ghostscript version is pinned in this repo.
For the same reason, damaged real files are asserted only to be refused with nothing published, not to land in one exact refusal class: which class they land in follows the installed reader's wording.
The `REJECTED` versus `CANNOT VERIFY` distinction is locked exactly by the stub-reader cases, where the suite controls the reader's output byte for byte.

The suite is not vacuous: replacing the gate with an unconditional success - which is behaviorally what an exit-code-only check would be here, since the reader exits 0 on the broken file - fails it at the first assertion.

The proof has to actually run.
Without Ghostscript the suite would skip and CI would stay green while nothing was checked, so the `portable-serial` lane in `.github/workflows/ci.yml` installs Ghostscript, requires it, and passes `--fail-on-gate-skip 'ghostscript not found'`, which turns that skip into a lane failure.
The lane is the single owner of that requirement.
A developer run without Ghostscript skips, as it does for every other optional-tool suite in this repo.

## Using it

Any path that generates a PDF finishes through `bin/fm-pdf-finish.sh` rather than writing its output file directly, and passes `--pages` whenever the expected length is known.
Use `bin/fm-pdf-verify.sh` on its own only to audit a file that already exists.
Both treat any non-zero exit as a failure, including exit 3, which means the check could not be performed.
Both need Ghostscript on the machine that generates, resolved through `FM_PDF_GS` and defaulting to `gs`; when it is absent they refuse with exit 3 and publish nothing rather than falling back to an unchecked file.

The failing document was assembled by splitting a browser-printed file and reuniting it, because the browser draws the page footer on the cover as well and the cover has to come from a separate footerless print.
That shape is fine; only the reassembly tool was wrong.
`pdfseparate` is not implicated and can still split, but the final join belongs to the gated step:

```
# before - produces a non-conforming file, and nothing notices
pdfseparate full.pdf body-%d.pdf     # drop page 1
pdfunite cover.pdf body-*.pdf out.pdf

# after - conforming producer, and the file is read back before it is published
pdfseparate -f 2 full.pdf body-%d.pdf
bin/fm-pdf-finish.sh --pages 27 out.pdf cover.pdf body-1.pdf body-2.pdf ...
```

Passing the parts straight to `bin/fm-pdf-finish.sh` also removes the separate merge tool: it concatenates its inputs in order, so the split-and-rejoin only needs poppler for the split.

One consequence worth knowing before comparing old and new output: rebuilding the document maps `fi` and `fl` to their ligature codepoints, so extracted text carries `ﬁ` where the browser's output carried `fi`.
Rendering is unchanged and the word count is identical; only text extraction and in-viewer search for those words differ.
This matches the repaired copy the captain already accepted, so it is the established baseline rather than a new change.
