#!/usr/bin/env python3
"""fm-curate-knowledge.py - the instrument behind /run-curate-knowledge.

WHY THIS IS A PROGRAM AND NOT A CHECKLIST
On 2026-08-16 this seat curated data/learnings.md by hand. The split executed
and nothing was curated: headings went 232 -> 252, content moved wholesale,
ten entries out of 254 vanished with no record of why. Startup cost fell 96
percent, which was worth having and was a different job from the one asked
for. Every failure in that list is mechanically detectable, so it is detected
here instead of being left to an agent's care:

  * headings rose            -> `check` fails when the TOTAL heading count does
                                not fall. Moving an entry whole from one file
                                to another leaves the total flat; that is the
                                exact signature of "the split executed, nothing
                                was curated".
  * nothing was folded       -> the inventory's DEFAULT verdict is `split`
                                (private files) or `stub` (shared files), so
                                dividing the entry is the path of least effort
                                and keeping it whole is what costs a sentence.
  * silent deletions         -> `check` recomputes what actually disappeared and
                                fails unless that set is exactly the set the
                                worksheet declared at the entry level. An
                                unlisted entry deletion cannot survive a run.
  * the archive went dark    -> `check` requires the route back to live INSIDE
                                the loaded half, requires that route to be a
                                runnable search command, and then RUNS every
                                documented search this guard can execute. Each
                                must run and return results; at least one must
                                be a heading index reaching every archived
                                entry, because only an index can carry
                                completeness. A worked content search is proved
                                by returning results and is not asked to be an
                                index. A documented command outside the provable
                                interface is reported rather than dropped only
                                when its FORM is one this guard recognises as
                                read-only; every other form FAILS, because the
                                harm is a reader following the document. Shell
                                syntax is refused before any of that: a run
                                whose lexer yields an unquoted operator is more
                                than one command and so is not one this guard
                                can classify. A run whose first word carries a
                                document suffix is prose naming a file, and is
                                passed over; every other first word is a command
                                word and is judged, so nothing is dropped in
                                silence. The route is proved, not asserted.

PROOF AND LEDGER UNIT
Both guarantees operate on entries at the selected heading level. Deeper
headings travel inside their parent entry, and `check` rejects any deeper
archive heading that lies outside every entry span. The ledger accounts for
entries appearing and disappearing. Changes inside a retained entry, whether
a nested heading, bullet, sentence, or paragraph, remain the curator's
judgement recorded by the split verdict rather than a mechanical ledger event.
Reachability is settled by LINE NUMBER: this program's parse is fence-aware and
the operator's `grep` is not, so a route record counts only when the line it
returned is a real entry's heading line and the text agrees. A fenced example
cannot stand in for the entry it quotes.

NON-WRITING ROUTE BOUNDARY
The guarantee is a closed interface of grep and rg, tools with no write
capability, resolved only from /usr/bin, /bin, or /usr/local/bin to an absolute
regular file that the current user cannot write. Every argument is restricted
to the closed read-only grammar, the documented relative path must resolve from
the operational home to the archive under check, no shell is involved, and
execution receives a sanitised environment. Defence in depth then mirrors the
documented relative path under a 0444 copy inside a 0555 directory and compares
the copy's hash before and after execution. The real archive is never executed
against, and a boundary that cannot establish every item in this list refuses.

ROUTE WORKING DIRECTORY
A documented route is written to be run from the operational home, because that
is where an operator reading the loaded half would run it: `data/learnings.md`
sends its reader to `grep -n '^## ' data/learnings-longterm.md`. So --home is
the route's working directory, the path argument resolves from there, and the
proof mirrors that same relative path under its protected directory so the
command runs verbatim. A staged pair that is not yet in place is checked by
pointing --home at the mirror the pair is staged in; `check` uses --home for
nothing else, while `report` uses it only for the share denominator.

WHAT THIS PROGRAM DOES NOT DO
It never decides hot from cold. There is no keyword heuristic anywhere in this
file, deliberately: the split criterion is "must this be in hand BEFORE the
problem appears", and no string match can answer that. The agent judges; this
program measures, records the judgement, and refuses a run that contradicts it.
It also never rewrites a knowledge file. Prose surgery is the agent's work; a
program that guessed at it would reintroduce the failure it exists to catch.

TWO SHAPES, NEVER INTERCHANGEABLE
  Shape `private`  - data/learnings.md, data/captain.md. Not tracked, no other
                     owner. Splits into a loaded half plus a real archive file
                     the session never reads.
  Shape `shared`   - AGENTS.md and the rest of firstmate's tracked material.
                     Gets NO archive. It is under a one-owner contract, so its
                     detail moves to the file that already owns it (a skill, a
                     doc, a script header) and an inline stub points there. A
                     second file full of AGENTS.md prose would be a second
                     owner, which is the defect, not the fix. See the
                     `firstmate-coding-guidelines` skill's inline-stub pattern.
Shape is taken from a recorded baseline or Git tracking. --shape is accepted
only for a staged file neither source can classify. The verdict vocabularies
do not overlap: `cold` and `split` are refused on a shared file, `stub` is the
shared file's default, and passing --archive for a shared shape is refused.

MEASUREMENT UNITS
Bytes and share of the startup surface. Never lines. Bytes per line is a house
style, not a cost: 77 here, 211 at hlr, 638 in hlr's captain.md, because that
home writes one sentence per line. A vessel comparing line counts against ours
exonerates itself while carrying the identical token cost. `--lines` exists
only to refuse and explain.

SHARE DENOMINATOR
Default is the startup surface this program can measure without touching the
fleet: AGENTS.md at the code root, the active roles/<name>.md overlay when
config/role selects one, and every data/*.md the session-start context digest
prints. That last list is EXTRACTED from bin/fm-session-start.sh at run time,
never restated here, so bin/fm-session-start.sh stays its single owner and the
denominator cannot drift away from what actually loads. Every run prints the
denominator's composition and what it excludes. Pass --against <file> to
measure against a captured real digest instead.

A share is only printed against a surface that exists. The workflow this skill
teaches stages the new pair outside the home and moves it in after the check
passes, so `report` resolves --loaded and asks whether that exact file is in the
measured surface. In place, the arithmetic is the surface as it stands. Staged,
the before share is measured against today's real surface and the after share is
labelled a PROJECTION of the surface once the pair is moved, because an
unlabelled share for a state that never existed is the same offence as pricing a
prune in lines. Under --against <captured digest> that question cannot be
answered at all - a digest is a byte size with no file list - so membership is
printed as UNMEASURED, both shares are against the digest as captured, and no
projection is offered. A reading this program could not take is reported as
unmeasured, never as a result.

Usage:
  fm-curate-knowledge.py measure [FILE...] [options]
      Per file: bytes, heading count, per-entry byte sizes, share of the
      denominator. With no FILE, measures the whole startup surface.
      --save <snapshot.json> writes the baseline `check` and `report` read.

  fm-curate-knowledge.py inventory FILE --out <worksheet.md> [options]
      One block per entry with its size and an empty verdict slot, pre-filled
      with the shape's dividing verdict. The agent fills it in; this program
      reads it back.

  fm-curate-knowledge.py check --before <snapshot.json> --worksheet <w.md>
                              --loaded FILE [--archive FILE]
                              [--before-loaded FILE --before-archive FILE]
                              [options]
      The gate. Exits non-zero on a failed prune. Name the pair with
      --before-loaded and --before-archive on any run whose archive already
      exists; see BASELINE MODES below.

  fm-curate-knowledge.py report --before <snapshot.json> --loaded FILE
                              --worksheet <w.md> [--archive FILE]
                              [--before-loaded FILE --before-archive FILE]
                              [options]
      Before/after in bytes and share, plus the deletion ledger with evidence.
      The worksheet is required: the ledger is the only record a deletion ever
      gets, so a report that could omit it is a report of the wrong thing.

BASELINE MODES, and the second one is the one that runs in service
A FIRST split has one before-state: the single file that is about to divide.
Name it with --before-file (or leave it implicit when the snapshot holds one
file) and the whole after-state, loaded plus archive, is compared against it.
Every run after that is a RE-RUN against an archive that already exists, and
the before-state is then the PAIR. Snapshot both files and name them with
--before-loaded and --before-archive: the baseline heading total becomes the sum
across the pair and the baseline entry occurrences become the combined set, so
the after-state is compared like for like. Without that, a perfect re-run fails
on a heading total that was never comparable (measured on this home: a loaded
half of 10 headings against a pair of 275), and a silently dropped archive entry
is invisible because the baseline never knew the archive existed. The mode is
chosen from the arguments, never guessed: pair mode requires both flags. Each
half keeps the entry level it was measured at, because the two routinely differ
and parsing either after-file at the other's level reports the whole archive as
deleted. A baseline's entries are fixed at snapshot time, so `check` and
`report` refuse --level outright in both modes rather than reparsing the
after-state at a level the baseline never used; --level belongs on `measure`
and `inventory`, which parse a file with no baseline to contradict.
Verdicts are still owed only for the entries of the before-LOADED half, because
a re-run curates what accumulated there while the archive's own entries are
accounted for by presence rather than by judgement.

Common options:
  --home <dir>     operational home holding data/ and config/ (default $FM_HOME,
                   else this checkout's root)
  --root <dir>     code root holding bin/ AGENTS.md roles/ (default: --home when
                   it has bin/fm-session-start.sh, else this checkout's root)
  --level <n>      heading level that delimits an entry (default: auto - the
                   level with the most headings in the file)
  --against <what> `startup` (default) or a path to a captured digest file
  --json           machine-readable output where the subcommand supports it

Exit status: 0 on success, 1 on a failed check or a refused run, 2 on a usage
error. `check` is a gate and its exit status is the verdict. `report` reports
AND refuses: it exits 2 without --worksheet, and 1 when that worksheet carries a
key the baseline never had, when an entry disappeared with nothing accounting
for it, or when a declared delete or fold is still present. A report is the
record a deletion gets, so it will not print one it cannot stand behind.
`measure` is the only pure reporting command, and exits 0 unless a path is
unreadable or --lines asks it to price a house style as a cost.
"""

import argparse
import atexit
from collections import Counter
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*$")

# bin/fm-session-start.sh step 6 prints each context file through this helper.
# Extracting the calls keeps that script the single owner of what loads.
DIGEST_CALL_RE = re.compile(r'print_file_or_absent\s+"\$DATA/([^"]+)"')

# This is a closed positive interface, not a list of commands believed to be
# harmless. grep and rg have no write operation, and every accepted option is
# enumerated below so an unknown flag cannot add capability. Every other tool
# is refused because it is outside this provably non-writing interface.
ROUTE_VERBS = ("grep", "rg")
TRUSTED_ROUTE_DIRS = ("/usr/bin", "/bin", "/usr/local/bin")
ROUTE_FLAGS = {
    "grep": ("-n", "-i", "-F", "-E", "-e", "-m", "--"),
    "rg": ("-n", "-i", "-F", "-e", "-m", "--"),
}
# Flags that consume the next argument. `-m` is also accepted glued to its
# count, as `grep -m1`, and both spellings are validated against ROUTE_FLAGS
# above so the enumerated set is the set actually enforced.
ROUTE_VALUE_FLAGS = ("-e", "-m")

# The closed set of read-only forms a documented command may take when this
# guard cannot execute it. A documented command outside this set FAILS the
# check: see guidance_form_error for why recognising destructive forms instead
# was tried, and abandoned.
GUIDANCE_FORMS = {
    "sed": ("-n",),
    "less": ("-N", "-S", "-R", "-F", "-X"),
    "cat": ("-n", "-b", "-s"),
    "head": ("-n", "-c"),
    "tail": ("-n", "-c"),
}
GUIDANCE_VALUE_FLAGS = {
    "head": ("-n", "-c"),
    "tail": ("-n", "-c"),
}

# Suffixes that make the first word of a backticked run a FILENAME rather than
# a command word, which is the one thing separating prose from a documented
# command. Every other first word is a command and is judged; see command_argv
# for why the unlisted case fails loudly instead of being dropped.
DOCUMENT_SUFFIXES = (
    ".md", ".markdown", ".rst", ".org", ".txt", ".text", ".log",
    ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env",
    ".csv", ".tsv", ".html", ".htm", ".xml", ".pdf", ".diff", ".patch",
)

# Verdict vocabularies. They do not overlap by accident: `cold` and `split`
# presuppose an archive file, which a shared-tracked file must never grow.
PRIVATE_VERDICTS = ("split", "hot", "cold", "fold", "delete")
SHARED_VERDICTS = ("stub", "hot", "fold", "delete")
DEFAULT_VERDICT = {"private": "split", "shared": "stub"}

# A `why` shorter than this is a label, not a reason. It is a floor that stops
# `why: old`, never a substitute for the judgement the agent still owes.
WHY_FLOOR = 16


def die(msg, code=2):
    sys.stderr.write("fm-curate-knowledge: %s\n" % msg)
    raise SystemExit(code)


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def norm_heading(text):
    """Identity for set comparison: level-insensitive, case-folded, despaced."""
    return re.sub(r"\s+", " ", text).strip().lower()


def occurrence_keys(headings):
    counts = {}
    keys = []
    for heading in headings:
        norm = norm_heading(heading)
        counts[norm] = counts.get(norm, 0) + 1
        keys.append("%s#%d" % (norm, counts[norm]))
    return keys


def split_occurrence_key(key):
    """The (norm, ordinal) an occurrence key encodes, or (None, None)."""
    match = re.fullmatch(r"(.*)#(\d+)", key.strip())
    if not match:
        return None, None
    return match.group(1), int(match.group(2))


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


def all_headings(text):
    """Every ATX heading, outside fenced code blocks, as (level, text)."""
    out = []
    fenced = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = HEADING_RE.match(line)
        if match:
            out.append((len(match.group(1)), match.group(2)))
    return out


def auto_level(text):
    """The level with the most headings. Ties resolve to the shallower level.

    Measured against this fleet's four real knowledge files, this picks `##`
    for every one of them: AGENTS.md 16 of 28, learnings.md 8 of 9,
    learnings-longterm.md 244 of 265, captain.md 76 of 85.
    """
    counts = {}
    for level, _ in all_headings(text):
        counts[level] = counts.get(level, 0) + 1
    if not counts:
        return 2
    best = max(counts.items(), key=lambda kv: (kv[1], -kv[0]))
    return best[0]


def parse_entries(text, level):
    """Split into entries at `level`. Returns (preamble_bytes, [entry, ...]).

    An entry runs from its heading line to the line before the next heading of
    the same or a shallower level, so a nested `###` stays with its parent.
    """
    lines = text.splitlines(keepends=True)
    fenced = False
    starts = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = HEADING_RE.match(line.rstrip("\n"))
        if match and len(match.group(1)) <= level:
            starts.append((index, len(match.group(1)), match.group(2)))

    entry_starts = [s for s in starts if s[1] == level]
    if not entry_starts:
        return sum(len(line.encode("utf-8")) for line in lines), []

    boundaries = [s[0] for s in starts]
    entries = []
    keys = occurrence_keys([entry[2] for entry in entry_starts])
    for (index, level_at, heading), key in zip(entry_starts, keys):
        following = [b for b in boundaries if b > index]
        end = following[0] if following else len(lines)
        body = "".join(lines[index:end])
        entries.append(
            {
                "heading": heading,
                "norm": norm_heading(heading),
                "key": key,
                "level": level_at,
                "line": index + 1,
                "bytes": len(body.encode("utf-8")),
            }
        )
    preamble = sum(len(line.encode("utf-8")) for line in lines[: entry_starts[0][0]])
    return preamble, entries


def orphan_nested_headings(text, level):
    """Deeper headings that lie outside every entry at `level`."""
    inside_entry = False
    orphans = []
    for heading_level, heading in all_headings(text):
        if heading_level < level:
            inside_entry = False
        elif heading_level == level:
            inside_entry = True
        elif not inside_entry:
            orphans.append(heading)
    return orphans


def file_facts(path, level=None):
    text = read_text(path)
    chosen = level or auto_level(text)
    preamble, entries = parse_entries(text, chosen)
    return {
        "path": os.path.abspath(path),
        "bytes": len(text.encode("utf-8")),
        "level": chosen,
        "heading_count_all": len(all_headings(text)),
        "preamble_bytes": preamble,
        "entries": entries,
    }


# --------------------------------------------------------------------------
# The denominator
# --------------------------------------------------------------------------


def digest_context_files(root):
    """The data/ files bin/fm-session-start.sh prints in its context digest.

    Extracted from that script rather than restated, so it stays the owner.
    """
    script = os.path.join(root, "bin", "fm-session-start.sh")
    if not os.path.isfile(script):
        return None
    names = []
    for name in DIGEST_CALL_RE.findall(read_text(script)):
        if name not in names:
            names.append(name)
    return names


def startup_surface(home, root):
    """Every file loaded before the first turn that this program can measure.

    Returns (rows, total_bytes, notes). A row is
    (label, path, bytes, present, source).
    """
    rows = []
    notes = []

    agents = os.path.join(root, "AGENTS.md")
    rows.append(
        (
            "AGENTS.md",
            agents,
            os.path.getsize(agents) if os.path.isfile(agents) else 0,
            os.path.isfile(agents),
            "harness project instructions",
        )
    )

    role_file = os.path.join(home, "config", "role")
    if os.path.isfile(role_file):
        role = read_text(role_file).strip()
        if role:
            overlay = os.path.join(root, "roles", "%s.md" % role)
            rows.append(
                (
                    "roles/%s.md" % role,
                    overlay,
                    os.path.getsize(overlay) if os.path.isfile(overlay) else 0,
                    os.path.isfile(overlay),
                    "config/role",
                )
            )
    else:
        notes.append("no config/role: default vessel, no overlay in the surface")

    names = digest_context_files(root)
    if names is None:
        notes.append(
            "bin/fm-session-start.sh not found under --root %s: "
            "context-digest files UNMEASURED, not absent" % root
        )
    else:
        for name in names:
            path = os.path.join(home, "data", name)
            rows.append(
                (
                    "data/%s" % name,
                    path,
                    os.path.getsize(path) if os.path.isfile(path) else 0,
                    os.path.isfile(path),
                    "bin/fm-session-start.sh context digest",
                )
            )
    total = sum(row[2] for row in rows)
    return rows, total, notes


def denominator(args):
    """Returns (label, bytes, rows, notes)."""
    if args.against != "startup":
        path = args.against
        if not os.path.isfile(path):
            die("--against %s is neither `startup` nor a readable file" % path)
        return (
            "captured digest %s" % path,
            os.path.getsize(path),
            [],
            ["denominator is the captured digest's own byte size"],
        )
    rows, total, notes = startup_surface(args.home, args.root)
    notes.append(
        "excluded from the denominator: bootstrap diagnostics, the supervision "
        "block, and the fleet-state digest (backlog, per-task records, status "
        "tails). The share below is therefore a FLOOR against a stated "
        "denominator, not a share of the whole session start. For that, "
        "capture a real digest and pass --against <file>."
    )
    return ("startup surface", total, rows, notes)


def pct(part, whole):
    if not whole:
        return "n/a"
    return "%.1f%%" % (100.0 * part / whole)


# --------------------------------------------------------------------------
# Shape
# --------------------------------------------------------------------------


def detect_shape(path, root):
    """Return a Git-derived shape, or None when Git cannot classify the path.

    Tracking is the real signal: shared tracked material is exactly the
    material other homes receive, and it is exactly the material under the
    one-owner contract that forbids an archive.
    """
    try:
        top_result = subprocess.run(
            ["git", "-C", root, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if top_result.returncode != 0:
            return None
        top = os.path.realpath(top_result.stdout.strip())
        target = os.path.realpath(os.path.abspath(path))
        if os.path.commonpath((top, target)) != top:
            return None
        result = subprocess.run(
            ["git", "-C", top, "ls-files", "--error-unmatch", target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, ValueError):
        return None
    return "shared" if result.returncode == 0 else "private"


def resolve_shape(args, path):
    detected = detect_shape(path, args.root)
    if args.shape and detected is not None:
        if args.shape != detected:
            die(
                "refused: --shape %s contradicts git tracking, which classifies "
                "%s as %s. Remove --shape to use the Git classification, or "
                "change which file or --root is being operated on"
                % (args.shape, path, detected),
                1,
            )
        die(
            "refused: --shape is only for a file Git cannot classify; git "
            "tracking already classifies %s as %s. Remove --shape to proceed"
            % (path, detected),
            1,
        )
    if args.shape:
        return args.shape
    return detected or "private"


def resolve_baseline_shape(args, before):
    recorded = before.get("shape")
    if args.shape and recorded is not None:
        if args.shape != recorded:
            die(
                "refused: --shape %s contradicts the recorded baseline shape, "
                "which says %s. Remove --shape to use the baseline, or create "
                "a new baseline from the intended file"
                % (args.shape, recorded),
                1,
            )
        die(
            "refused: --shape is only for an unclassifiable baseline; the "
            "recorded baseline shape already says %s. Remove --shape to proceed"
            % recorded,
            1,
        )

    baseline_path = before.get("loaded_path") or before.get("path")
    detected = detect_shape(baseline_path, args.root)
    if args.shape and detected is not None:
        if args.shape != detected:
            die(
                "refused: --shape %s contradicts git tracking, which classifies "
                "%s as %s. Remove --shape to use the Git classification, or "
                "create a baseline from the intended file"
                % (args.shape, baseline_path, detected),
                1,
            )
        die(
            "refused: --shape is only for an unclassifiable baseline; git "
            "tracking already classifies %s as %s. Remove --shape to proceed"
            % (baseline_path, detected),
            1,
        )
    if args.shape:
        return args.shape
    return recorded or detected or "private"


# --------------------------------------------------------------------------
# Worksheet
# --------------------------------------------------------------------------


WORKSHEET_HEADER = """\
# fm-curate-knowledge worksheet v1
# file: {path}
# shape: {shape}
# level: {level}
# entries: {count}
# bytes: {bytes}
#
# THE SPLIT CRITERION, and it is not age.
#   Must this fact be in hand BEFORE the problem appears?
#     Yes -> it stays loaded. By the time an agent thinks to look it up it has
#            already done the thing.
#     No  -> the trigger arrives WITH the problem, so an agent will go looking.
#            It belongs in the archive.
#   Age is not the test. It is the obvious axis and it is the wrong one: it
#   puts permanent safety facts in the archive and last week's trivia in the
#   loaded half.
#
# VERDICTS for shape {shape}: {vocab}
# The default below is `{default}` on every entry. {rationale}
# Keeping an entry whole is the deviation, and it costs a `why:` of at least
# {floor} characters.
{verdict_help}#
# Fill `verdict:` and `why:` on every block. Leave nothing blank.

"""

PRIVATE_RATIONALE = (
    "Most entries hold BOTH a hot rule and a\n"
    "# cold incident, and filing one whole to a side is exactly what leaves a\n"
    "# heading count flat while the body just changes address."
)

SHARED_RATIONALE = (
    "This file is under a one-owner contract, so\n"
    "# nearly every fact in it already has a better home and belongs here only\n"
    "# as the pointer that survives with no skill loaded."
)

PRIVATE_HELP = """\
#   split  - (default) the entry is divided: the RULE it taught stays loaded and
#            the incident goes to the archive. Either half may keep this
#            heading. why: must name the heading the OTHER half now lives under,
#            because that is the half the driver cannot find on its own.
#            Heading-neutral - a split moves a heading, it never adds one, so
#            only folds and deletions make the count fall.
#   hot    - the whole entry stays loaded. why: what makes all of it needed
#            before the problem appears.
#   cold   - the whole entry moves to the archive. why: what makes none of it
#            needed in advance.
#   fold   - merged into another entry, heading gone. why: must name the
#            surviving heading it merged into.
#   delete - gone entirely. why: the EVIDENCE that killed it - the commit, the
#            command, the file that no longer exists. Judgement archives; only
#            proof deletes.
"""

SHARED_HELP = """\
#   stub   - (default) the detail moves to the file that ALREADY OWNS it - a
#            skill, a doc, a script header - and an inline pointer stays here.
#            why: must name that owner path. There is no archive for a shared
#            tracked file; a second file of its prose would be a second owner.
#   hot    - stays here whole. why: what makes it needed on every session.
#   fold   - merged into another section, heading gone. why: must name the
#            surviving heading.
#   delete - gone entirely. why: the EVIDENCE that killed it.
"""


def write_worksheet(path, facts, shape, out):
    vocab = PRIVATE_VERDICTS if shape == "private" else SHARED_VERDICTS
    body = [
        WORKSHEET_HEADER.format(
            path=path,
            shape=shape,
            level=facts["level"],
            count=len(facts["entries"]),
            bytes=facts["bytes"],
            vocab=" | ".join(vocab),
            default=DEFAULT_VERDICT[shape],
            floor=WHY_FLOOR,
            rationale=PRIVATE_RATIONALE if shape == "private" else SHARED_RATIONALE,
            verdict_help=PRIVATE_HELP if shape == "private" else SHARED_HELP,
        )
    ]
    for index, entry in enumerate(facts["entries"], start=1):
        body.append(
            "--- entry {n}\n"
            "key: {key}\n"
            "heading: {heading}\n"
            "bytes: {bytes}\n"
            "share_of_file: {share}\n"
            "verdict: {default}\n"
            "why:\n\n".format(
                n=index,
                key=entry["key"],
                heading=entry["heading"],
                bytes=entry["bytes"],
                share=pct(entry["bytes"], facts["bytes"]),
                default=DEFAULT_VERDICT[shape],
            )
        )
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("".join(body))


def read_worksheet(path):
    """Parse a filled worksheet. Returns (meta, rows)."""
    meta = {}
    rows = []
    current = None
    key = None
    for raw in read_text(path).splitlines():
        if raw.startswith("#"):
            match = re.match(r"^#\s*([a-z_]+):\s*(.*)$", raw)
            if match and match.group(1) in ("file", "shape", "level", "entries"):
                meta[match.group(1)] = match.group(2).strip()
            continue
        if raw.startswith("--- entry"):
            if current:
                rows.append(current)
            current = {"n": raw.split()[-1], "key": "", "heading": "", "verdict": "", "why": ""}
            key = None
            continue
        if current is None:
            continue
        match = re.match(r"^([a-z_]+):\s*(.*)$", raw)
        if match and match.group(1) in (
            "key",
            "heading",
            "bytes",
            "share_of_file",
            "verdict",
            "why",
        ):
            key = match.group(1)
            current[key] = match.group(2).strip()
            continue
        if key in ("why", "heading") and raw.strip():
            current[key] = (current[key] + " " + raw.strip()).strip()
    if current:
        rows.append(current)
    generated = occurrence_keys([row["heading"] for row in rows])
    for row, generated_key in zip(rows, generated):
        if not row["key"]:
            row["key"] = generated_key
        heading_norm = norm_heading(row["heading"])
        # The key already encodes the norm, so the norm every later comparison
        # runs on is taken FROM the key rather than re-derived from the heading
        # text. A row whose heading has drifted from its key would otherwise be
        # validated by the key and then counted by a norm the baseline never
        # had, which is a deletion ledger entry nothing checks.
        key_norm, _ordinal = split_occurrence_key(row["key"])
        row["norm"] = heading_norm if key_norm is None else key_norm
        row["key_conflict"] = key_norm is not None and key_norm != heading_norm
    return meta, rows


def key_conflicts(rows):
    """Rows whose `heading:` contradicts the norm inside their own `key:`."""
    return [row for row in rows if row.get("key_conflict")]


def key_conflict_message(row):
    key_norm, _ordinal = split_occurrence_key(row["key"])
    return (
        "entry %s carries key `%s` but heading `%s`, which normalises to `%s`; "
        "one of the two is wrong and the driver will not guess which"
        % (row["n"], row["key"], row["heading"][:60], norm_heading(row["heading"]))
        if key_norm is not None
        else "entry %s carries an unreadable key `%s`" % (row["n"], row["key"])
    )


# --------------------------------------------------------------------------
# measure
# --------------------------------------------------------------------------


def cmd_measure(args):
    if args.lines:
        die(
            "refused: this program does not report line counts.\n"
            "  Bytes per line is a house style, not a cost. Measured across "
            "three seats: 77 here, 211 at hlr, 638 in hlr's captain.md, "
            "because that home writes one sentence per line.\n"
            "  A vessel that compares line counts against ours exonerates "
            "itself while carrying the identical token cost.\n"
            "  Report bytes and share of the startup surface instead.",
            2,
        )

    label, total, rows, notes = denominator(args)
    targets = list(args.files)
    if not targets:
        targets = [row[1] for row in rows if row[3]]

    payload = {"denominator": {"label": label, "bytes": total}, "files": {}}

    human = sys.stderr if args.json else sys.stdout
    print("DENOMINATOR: %s = %d bytes" % (label, total), file=human)
    for row_label, path, size, present, source in rows:
        print(
            "  %-28s %10s  %7s  %s"
            % (
                row_label,
                ("%d B" % size) if present else "ABSENT",
                pct(size, total) if present else "-",
                source,
            )
        , file=human)
    for note in notes:
        print("  note: %s" % note, file=human)
    print("", file=human)

    for target in targets:
        if not os.path.isfile(target):
            die("not a readable file: %s" % target, 1)
        facts = file_facts(target, args.level)
        shape = resolve_shape(args, target)
        facts["shape"] = shape
        payload["files"][facts["path"]] = facts

        print("FILE: %s" % target, file=human)
        print("  shape             %s" % shape, file=human)
        print(
            "  bytes             %d  (%s of the %s)"
            % (facts["bytes"], pct(facts["bytes"], total), label)
        , file=human)
        print(
            "  headings          %d total, %d at level %d (the entry level)"
            % (facts["heading_count_all"], len(facts["entries"]), facts["level"])
        , file=human)
        print(
            "  preamble          %d bytes before the first entry"
            % facts["preamble_bytes"]
        , file=human)
        if facts["entries"]:
            sizes = sorted(e["bytes"] for e in facts["entries"])
            middle = sizes[len(sizes) // 2]
            print(
                "  entry bytes       median %d, largest %d, smallest %d"
                % (middle, sizes[-1], sizes[0])
            , file=human)
            top = sorted(facts["entries"], key=lambda e: -e["bytes"])[: args.top]
            print("  largest %d entries:" % len(top), file=human)
            for entry in top:
                print(
                    "    %8d B  %6s of file  %6s of surface  %s"
                    % (
                        entry["bytes"],
                        pct(entry["bytes"], facts["bytes"]),
                        pct(entry["bytes"], total),
                        entry["heading"],
                    )
                , file=human)
        print("", file=human)

    if args.save:
        payload["denominator"]["rows"] = [
            {"label": r[0], "path": r[1], "bytes": r[2], "present": r[3]} for r in rows
        ]
        with open(args.save, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
        print("SNAPSHOT: wrote %s" % args.save, file=human)

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


# --------------------------------------------------------------------------
# inventory
# --------------------------------------------------------------------------


def cmd_inventory(args):
    target = args.file
    if not os.path.isfile(target):
        die("not a readable file: %s" % target, 1)
    shape = resolve_shape(args, target)
    facts = file_facts(target, args.level)
    if not facts["entries"]:
        die("no level-%d headings in %s: nothing to inventory" % (facts["level"], target), 1)
    write_worksheet(target, facts, shape, args.out)
    print(
        "INVENTORY: %d entries from %s (shape %s, level %d) -> %s"
        % (len(facts["entries"]), target, shape, facts["level"], args.out)
    )
    print(
        "  every verdict is pre-filled `%s`. Change one only with a `why:` of "
        "at least %d characters." % (DEFAULT_VERDICT[shape], WHY_FLOOR)
    )
    return 0


# --------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------


def load_snapshot(path, before_file):
    with open(path, "r", encoding="utf-8") as handle:
        snap = json.load(handle)
    files = snap.get("files", {})
    if not files:
        die("snapshot %s records no files" % path)
    if before_file:
        key = os.path.abspath(before_file)
        if key not in files:
            die(
                "snapshot %s has no entry for %s (has: %s)"
                % (path, key, ", ".join(sorted(files)))
            )
        return snap, files[key]
    if len(files) != 1:
        die(
            "snapshot %s records %d files; name the baseline with --before-file"
            % (path, len(files))
        )
    return snap, list(files.values())[0]


def snapshot_record(snap, path, snapshot_path):
    files = snap.get("files", {})
    key = os.path.abspath(path)
    if key not in files:
        die(
            "snapshot %s has no entry for %s (has: %s)"
            % (snapshot_path, key, ", ".join(sorted(files)))
        )
    return files[key]


def baseline_entries_with_keys(record):
    """A record's entries, each carrying an occurrence key.

    A snapshot written before keys existed is read by regenerating them the
    same way the writer would have, so an older baseline still compares.
    """
    fallback = occurrence_keys([entry["heading"] for entry in record["entries"]])
    out = []
    for entry, fallback_key in zip(record["entries"], fallback):
        merged = dict(entry)
        merged["key"] = entry.get("key") or fallback_key
        merged["norm"] = entry.get("norm") or norm_heading(entry["heading"])
        out.append(merged)
    return out


def load_baseline(args):
    """The before-state, as one file or as the pair a re-run starts from.

    Returns a baseline dict shaped like a file record, plus the fields only a
    pair can answer: `loaded_heading_count`, which is what the loaded half must
    fall below, `verdict_keys`, the entries a worksheet still owes a judgement
    for, and one entry level PER HALF. The two halves routinely settle at
    different levels - a pruned loaded half of a title and one section resolves
    to level 1 while its archive of many sections resolves to 2 - so parsing
    either after-file at the other's level reports the whole archive as deleted.
    In single mode all of these collapse to the one baseline file.
    """
    with open(args.before, "r", encoding="utf-8") as handle:
        snap = json.load(handle)
    if not snap.get("files"):
        die("snapshot %s records no files" % args.before)

    pair_flags = (args.before_loaded, args.before_archive)
    if any(pair_flags) and not all(pair_flags):
        die(
            "--before-loaded and --before-archive name the two halves of a "
            "re-run's before-state; pass both or neither",
            2,
        )
    if any(pair_flags) and args.before_file:
        die(
            "--before-file selects a single baseline file; it cannot be combined "
            "with the pair baseline of --before-loaded and --before-archive",
            2,
        )

    # A baseline's entry set is fixed at snapshot time, so an override that
    # lands on the after-state alone compares unlike things. That is true of one
    # baseline file exactly as it is of a pair, and in single mode it used to
    # fail silently: a wrong --level turned a correct curation into invented
    # undeclared deletions and quietly emptied the archive of entries to prove
    # reachable. --level belongs on `measure` and `inventory`, which parse a
    # file with no baseline to contradict.
    if args.level:
        die(
            "--level cannot be set on a run that reads a baseline: the "
            "snapshot's entries were measured at the level it recorded. "
            "Snapshot with `measure --level <n>` and let this command follow "
            "what the snapshot recorded",
            2,
        )

    if not any(pair_flags):
        _snap, record = load_snapshot(args.before, args.before_file)
        baseline = dict(record)
        baseline["entries"] = baseline_entries_with_keys(record)
        baseline["loaded_heading_count"] = record["heading_count_all"]
        baseline["verdict_keys"] = {entry["key"] for entry in baseline["entries"]}
        baseline["loaded_level"] = record["level"]
        baseline["archive_level"] = record["level"]
        baseline["mode"] = "single"
        return baseline

    loaded_record = snapshot_record(snap, args.before_loaded, args.before)
    archive_record = snapshot_record(snap, args.before_archive, args.before)
    if loaded_record["path"] == archive_record["path"]:
        die("--before-loaded and --before-archive name the same file", 2)

    loaded_entries = baseline_entries_with_keys(loaded_record)
    # The loaded half comes first so its per-file occurrence keys are unchanged
    # by the combination, which is what lets a worksheet inventoried from that
    # file alone still name its own entries.
    archive_entries = []
    counts = Counter(entry["norm"] for entry in loaded_entries)
    for entry in baseline_entries_with_keys(archive_record):
        merged = dict(entry)
        counts[merged["norm"]] += 1
        merged["key"] = "%s#%d" % (merged["norm"], counts[merged["norm"]])
        archive_entries.append(merged)

    baseline = dict(loaded_record)
    baseline["path"] = "%s + %s" % (loaded_record["path"], archive_record["path"])
    # Bytes stay the LOADED half's, because startup cost is what the loaded half
    # spends. Summing the pair would make "the loaded half got smaller" trivially
    # true and retire the gate that measures the point of the exercise.
    baseline["bytes"] = loaded_record["bytes"]
    baseline["heading_count_all"] = (
        loaded_record["heading_count_all"] + archive_record["heading_count_all"]
    )
    baseline["loaded_heading_count"] = loaded_record["heading_count_all"]
    baseline["entries"] = loaded_entries + archive_entries
    baseline["verdict_keys"] = {entry["key"] for entry in loaded_entries}
    baseline["loaded_level"] = loaded_record["level"]
    baseline["archive_level"] = archive_record["level"]
    baseline["mode"] = "pair"
    baseline["loaded_path"] = loaded_record["path"]
    baseline["archive_path"] = archive_record["path"]
    return baseline


def baseline_levels(before):
    """The entry level to parse each after-file at, one per half."""
    loaded_level = before.get("loaded_level") or before.get("level")
    archive_level = before.get("archive_level") or before.get("level")
    return loaded_level, archive_level


def shell_syntax_error(command):
    """Why a documented run is shell SYNTAX rather than one command.

    `shlex.split` tokenizes; it does not parse a shell. It does not treat `;`,
    `|`, `&&` or a glued `>file` as operators, so a classifier reading argv[0]
    sees only the first word and everything after the operator is invisible:
    `cat fresh.md; rm <archive>` reads as the read-only form `cat`. The answer
    is not to split on operators and classify each part, which rebuilds a shell
    parser here and lets the next operator nobody thought of walk through the
    same way. Shell syntax is refused BEFORE classification: this guard judges
    one command, so anything that is more than one is something it cannot judge
    and must say so.

    The lexer does that judging, and searching the raw string does not. An
    operator inside a QUOTED operand is not an operator - no shell treats the
    `|` in `grep -n -E 'a|b' <archive>` as one - so a raw-string search refuses
    the worked content search the loaded half is asked to show, while still
    missing a glued `>file`. `shlex.shlex(command, punctuation_chars=True)`
    settles both: unquoted `;`, `|`, `&&`, `<`, `>` and the parens of a command
    substitution come back as their own tokens, and a quoted operand comes back
    whole.
    """
    if "\n" in command:
        return (
            "it spans more than one line, so it is not a single command this "
            "guard can classify"
        )
    lexer = shlex.shlex(command, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return None
    punctuation = lexer.punctuation_chars
    for token in tokens:
        if token and all(char in punctuation for char in token):
            return (
                "it carries shell syntax (`%s`), so it is not a single command "
                "this guard can classify" % token
            )
        quoted = token[:1] in ("'", '"')
        if not quoted and ("${" in token or "`" in token):
            return (
                "it carries a shell expansion (`%s`), so what it would run is "
                "not fixed and this guard cannot classify it" % token
            )
    return None


def command_argv(command):
    """Tokenize a backticked run, or None when it is not a command at all.

    A loaded half is prose with commands inside it, so the two must be told
    apart before either is judged. A run whose first word is a filename -
    `before.md -> after-archive.md`, this repo's own house arrow between two
    paths - is a sentence, and treating it as a documented route both accuses
    the curator of something they did not write and fails a correct curation.

    ONE rule decides it, because the pile of prefix rules this replaced was
    wrong in both directions at once: it dropped `bin/rebuild-archive.sh
    <archive>` in silence for having a slash without a leading dot, and it
    judged `/tmp/x/before.md -> /tmp/x/after.md` as a command for having a
    leading slash. The rule is the SUFFIX of the first word's basename. A
    document or data suffix means a filename, so the run is prose and is passed
    over; anything else is a command word and is judged, which is how a script
    invocation reaches the closed read-only set and fails there as unrecognised.

    The residual, stated rather than hidden: a first word carrying a suffix
    nobody listed is treated as a command and FAILS loudly as unrecognised,
    never dropped. That direction is deliberate - a loud false failure is
    visible to the operator and correctable in one edit, while a silent drop is
    neither, and never-drop is the invariant this guard exists to hold. Scraping
    prose for commands is ambiguous at the root; whether the loaded half should
    MARK its route explicitly instead is a separate question for the owner and
    is not implemented here.
    """
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if len(argv) < 2:
        return None
    suffix = os.path.splitext(os.path.basename(argv[0]))[1].lower()
    if suffix in DOCUMENT_SUFFIXES:
        return None
    return argv


def route_commands(loaded_text, archive_path):
    """Backtick-delimited commands that name the archive.

    A backticked run of text with no whitespace is the archive's ADDRESS, not a
    route to it, whether it is written as the bare name or as the home-relative
    path the route itself uses. Taking one for the route would reject a loaded
    half that names the file and then hands over a working search, which is how
    this home's real data/learnings.md is written. A location with no command
    still fails, one line further down, as the location it is. Prose that does
    not parse as a command is not a route either, and is passed over in silence
    rather than reported or failed.
    """
    base = os.path.basename(archive_path)
    found = []
    for command in re.findall(r"`([^`]+)`", loaded_text):
        stripped = command.strip().lstrip("$").strip()
        if base in command and command_argv(stripped):
            found.append(stripped)
    return found


_PROOF_DIRS = set()
_PROOF_SIGNALS_INSTALLED = False


def _restore_and_remove(path):
    """Undo the protection bits, then remove the directory.

    A 0555 directory of 0444 files cannot be removed by its owner without this,
    so a proof that ends any way other than normally must still hand the
    directory back removable.
    """
    if not os.path.isdir(path):
        return
    try:
        os.chmod(path, 0o755)
        for root, dirs, files in os.walk(path):
            os.chmod(root, 0o755)
            for directory in dirs:
                os.chmod(os.path.join(root, directory), 0o755)
            for name in files:
                os.chmod(os.path.join(root, name), 0o644)
    except OSError:
        pass
    shutil.rmtree(path, ignore_errors=True)


def _cleanup_proof_dirs():
    for path in sorted(_PROOF_DIRS):
        _restore_and_remove(path)
    _PROOF_DIRS.clear()


def _proof_signal_handler(signum, _frame):
    _cleanup_proof_dirs()
    raise SystemExit(128 + signum)


def _register_proof_dir(path):
    """Track a protected directory so it is cleaned up however the run ends.

    atexit covers a normal exit and an uncaught exception; the SIGINT and
    SIGTERM handlers cover an interrupted run. SIGKILL cannot be trapped, so a
    stale directory remains possible - which is part of why this lives under
    TMPDIR, where a leftover is harmless.
    """
    global _PROOF_SIGNALS_INSTALLED
    _PROOF_DIRS.add(path)
    if _PROOF_SIGNALS_INSTALLED:
        return
    _PROOF_SIGNALS_INSTALLED = True
    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(signum, _proof_signal_handler)
        except (ValueError, OSError):
            pass


def _release_proof_dir(path):
    _restore_and_remove(path)
    _PROOF_DIRS.discard(path)


atexit.register(_cleanup_proof_dirs)


def guidance_form_error(command):
    """Why a documented command is not a RECOGNISED read-only guidance form.

    Returns None when the command matches the closed set below, and the reason
    it does not otherwise. Read the direction carefully, because this is the
    second attempt and the first one was wrong in a way worth recording.

    The first attempt enumerated destructive FORMS - in-place flags, awk
    system(), tee, dd - and reported everything else as harmless. It was told
    about `sed -i` and stayed silent about `rm`, `mv`, `truncate` and `cp` over
    the archive, which is the maximal form of the very harm the failure names.
    Recognition-of-bad cannot work here. Fail-safe about EXECUTION is not
    fail-safe about the HARM: nothing with an unsupported verb is ever executed,
    so the danger is not this program running a writer, it is a HUMAN reading
    the loaded half and following it. An unrecognised form must therefore FAIL
    rather than pass, which is the same property the execution guard has.

    So the set is positive and closed: `sed` in its `-n` range-read form,
    `less`, `cat`, `head`, `tail`, with their arguments validated because the
    verb alone does not settle it - `sed -i` writes and `less -o` logs. Anything
    else fails, including verbs nobody has thought of yet.

    The honest limit: this program cannot PROVE an unexecuted command is
    read-only. A command it accepts here is read-only in FORM only.
    """
    syntax = shell_syntax_error(command)
    if syntax:
        return syntax
    argv = command_argv(command)
    if argv is None:
        return "it does not parse as a command"
    verb = os.path.basename(argv[0])
    if verb not in GUIDANCE_FORMS:
        return (
            "`%s` is not one of the read-only forms this guard recognises (%s)"
            % (verb, ", ".join(sorted(GUIDANCE_FORMS)))
        )
    allowed = GUIDANCE_FORMS[verb]
    index = 1
    while index < len(argv):
        token = argv[index]
        if not token.startswith("-") or token == "-":
            index += 1
            continue
        if verb in ("head", "tail") and re.fullmatch(r"[-+]\d+", token):
            index += 1
            continue
        name = token.split("=", 1)[0]
        base_flag = re.sub(r"\d+$", "", name)
        if name not in allowed and base_flag not in allowed:
            return "flag `%s` is outside its read-only form" % token
        if name in GUIDANCE_VALUE_FLAGS.get(verb, ()) and name == token:
            index += 1
        index += 1
    if verb == "sed" and "-n" not in argv:
        return "`sed` is read-only guidance only in its `-n` range-read form"
    return None


def prove_route(command, home, archive_path, entries, sample, trusted_dirs=None):
    """Run the documented route once and check every archived entry.

    `home` is the working directory the documented route is written to run
    from, so every relative path in it resolves from there and the proof
    mirrors that relative path under its protected directory. `entries` are the
    archive's parsed entries, each with the line its heading sits on, which is
    what the route's own output is matched against.
    """
    try:
        argv = shlex.split(command)
    except ValueError as exc:
        return "refused", [], [], "route cannot be tokenized: %s" % exc
    if not argv or os.path.basename(argv[0]) not in ROUTE_VERBS:
        return "refused", [], [], (
            "route command `%s` cannot be proven non-writing; document the "
            "route with grep or rg"
        ) % (argv[0] if argv else "")
    syntax = shell_syntax_error(command)
    if syntax:
        return "refused", [], [], "route is not a single command: %s" % syntax
    option_error, file_args = _validate_route_argv(argv)
    if option_error:
        return "refused", [], [], option_error
    executable, executable_error = _trusted_route_binary(
        argv[0], TRUSTED_ROUTE_DIRS if trusted_dirs is None else trusted_dirs
    )
    if executable_error:
        return "refused", [], [], executable_error
    home_dir = os.path.realpath(home)
    archive_real = os.path.realpath(archive_path)
    # An absolute path is refused for what it actually is - a path this proof
    # cannot mirror into its protected directory - rather than being left to
    # fall through to the mismatch branch, which would tell an operator that a
    # path resolves to itself and is therefore not itself.
    absolute_args = [index for index in file_args if os.path.isabs(argv[index])]
    if absolute_args:
        return "refused", [], [], (
            "documented path `%s` is absolute and cannot be mirrored into the "
            "protected proof directory; document the route relative to the "
            "home, as `data/<name>.md`" % argv[absolute_args[0]]
        )
    resolved_args = {
        index: os.path.realpath(os.path.join(home_dir, argv[index]))
        for index in file_args
    }
    archive_args = [
        index for index, resolved in resolved_args.items() if resolved == archive_real
    ]
    if not archive_args:
        documented = argv[file_args[-1]] if file_args else "(none)"
        documented_real = (
            os.path.realpath(os.path.join(home_dir, documented))
            if documented != "(none)"
            else documented
        )
        return "refused", [], [], (
            "documented archive path `%s` resolves to `%s`, not archive `%s`; "
            "the documented route is broken from a normal shell"
            % (documented, documented_real, archive_real)
        )
    if len(archive_args) != 1:
        return "refused", [], [], "route must name the archive exactly once"
    archive_index = archive_args[0]
    documented_archive = argv[archive_index]
    if ".." in documented_archive.split(os.sep):
        return "refused", [], [], (
            "documented archive path `%s` cannot be mirrored into the protected "
            "proof directory; document it relative to the home without `..`"
            % documented_archive
        )
    if not file_args:
        return "refused", [], [], "route has no archive path argument"
    # TMPDIR, never the current directory. Run the documented way, `check` is
    # invoked from the operational home or a repo checkout, and this program
    # promises to write to neither. A leftover proof directory under TMPDIR is
    # harmless; one in the operational home is not.
    try:
        temp_path = tempfile.mkdtemp(prefix="fm-route-proof-")
    except OSError as exc:
        return "refused", [], [], "route proof directory could not be created: %s" % exc
    _register_proof_dir(temp_path)
    copied = {}
    try:
        for index in file_args:
            value = argv[index]
            if ".." in value.split(os.sep):
                return "refused", [], [], "route file path `%s` cannot be mapped safely" % value
            candidate = os.path.realpath(os.path.join(home_dir, value))
            if not os.path.isfile(candidate):
                continue
            destination = os.path.join(temp_path, value)
            name = os.path.relpath(destination, temp_path)
            if name in copied and copied[name] != candidate:
                return "refused", [], [], "route maps two different files to %s" % name
            if name not in copied:
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                shutil.copyfile(candidate, destination)
                os.chmod(destination, 0o444)
                copied[name] = candidate
        archive_copy = os.path.join(temp_path, documented_archive)
        if not os.path.isfile(archive_copy):
            return "refused", [], [], "documented archive path was not copied for proof"
        hashes_before = {
            name: _file_hash(os.path.join(temp_path, name)) for name in copied
        }
        for root, dirs, _files in os.walk(temp_path, topdown=False):
            for directory in dirs:
                os.chmod(os.path.join(root, directory), 0o555)
        os.chmod(temp_path, 0o555)
        run_argv = [executable] + argv[1:]
        try:
            result = subprocess.run(
                run_argv,
                cwd=temp_path,
                capture_output=True,
                text=True,
                check=False,
                env={"PATH": os.pathsep.join(TRUSTED_ROUTE_DIRS), "LC_ALL": "C.UTF-8"},
            )
        except OSError as exc:
            return "refused", [], [], "route could not run: %s" % exc
        finally:
            os.chmod(temp_path, 0o755)
        hashes_after = {
            name: _file_hash(os.path.join(temp_path, name))
            if os.path.isfile(os.path.join(temp_path, name)) else None
            for name in copied
        }
        changed = sorted(name for name in copied if hashes_before[name] != hashes_after[name])
        if changed:
            return "refused", [], [], "route changed protected proof copies: %s" % ", ".join(changed)
    finally:
        _release_proof_dir(temp_path)
    output = result.stdout.strip()
    if result.returncode != 0 or result.stderr.strip() or not output:
        return "refused", [], [], "documented route exited %d, wrote diagnostics, or returned no output" % result.returncode
    # Two parsers disagree here, and the reconciliation is the point. This
    # driver's own parse is fence-aware and deliberately excludes headings
    # inside fenced code blocks; the documented route is an operator's ordinary
    # `grep -n '^## '`, which is not, and cannot be asked to be. So a record is
    # counted only when the LINE NUMBER grep already returned is the line of a
    # real entry, and its text agrees with that entry. A fenced `## Example`
    # then cannot stand in for the real entry of the same name, which with a
    # truncating route would otherwise read as full reach.
    expected = {entry["line"]: norm_heading(entry["heading"]) for entry in entries}
    reached_lines = set()
    output_lines = output.splitlines()
    is_index = bool(output_lines)
    for output_line in output_lines:
        match = re.fullmatch(r"(\d+):(#{1,6})[ \t]+(.*?)[ \t]*", output_line)
        if not match:
            # Not an index, which is not a fault. A worked CONTENT search is
            # exactly what rule 3 asks a loaded half to document, and it is
            # proven by running and returning results. Only an index can carry
            # the completeness assertion, so this command simply does not carry
            # it; at least one that does is required elsewhere.
            is_index = False
            break
        line_number = int(match.group(1))
        if expected.get(line_number) == norm_heading(match.group(3)):
            reached_lines.add(line_number)
    lines = ["  $ (protected copy && %s)" % " ".join(_shell_quote(part) for part in run_argv)]
    for line in output_lines[:sample]:
        lines.append("    %s" % line[:160])
    if not is_index:
        return (
            "results",
            lines,
            [],
            "search returned %d line(s); not a heading index, so it carries no "
            "completeness claim" % len(output_lines),
        )
    missing = [
        entry["heading"] for entry in entries if entry["line"] not in reached_lines
    ]
    return (
        "complete" if not missing else "incomplete",
        lines,
        missing,
        "route reaches %d of %d archived entries" % (len(reached_lines), len(entries)),
    )


def _validate_route_argv(argv):
    """Validate every option against ROUTE_FLAGS and return the path operands.

    One pass does both jobs. Walking the argument list twice, once to judge and
    once to locate operands, is how the two walks drift apart and a flag ends up
    accepted by one and unknown to the other.
    """
    allowed = ROUTE_FLAGS[os.path.basename(argv[0])]
    positional_indices = []
    has_expression = False
    index = 1
    options_done = False
    while index < len(argv):
        value = argv[index]
        if not options_done and value == "--":
            options_done = True
        elif not options_done and value in ROUTE_VALUE_FLAGS:
            if value not in allowed:
                return "route flag `%s` is not in the closed read-only set" % value, []
            has_expression = has_expression or value == "-e"
            index += 1
            if index >= len(argv):
                return "route flag `%s` requires a value" % value, []
            if value == "-m" and not argv[index].isdigit():
                return "route -m value must be a non-negative integer", []
        elif not options_done and re.fullmatch(r"-m\d+", value):
            if "-m" not in allowed:
                return "route flag `-m` is not in the closed read-only set", []
        elif not options_done and value.startswith("-"):
            if value not in allowed:
                return "route flag `%s` is not in the closed read-only set" % value, []
        else:
            positional_indices.append(index)
        index += 1
    if not positional_indices:
        return "route has no pattern or path operands", []
    file_indices = positional_indices if has_expression else positional_indices[1:]
    if not file_indices:
        return "route has no path operand", []
    return None, file_indices


def _trusted_route_binary(word, trusted_dirs):
    """The absolute binary to run for a documented verb, or the refusal.

    A documented route may spell its tool as a bare name or as a path. Either
    way the binary that runs is decided here and nowhere else: it must resolve
    into a trusted system directory, be a regular file, and not be writable by
    the current user. A path spelling buys no trust of its own.
    """
    trusted_real_dirs = {os.path.realpath(directory) for directory in trusted_dirs}
    if "/" in word:
        resolved = os.path.realpath(word)
        if os.path.dirname(resolved) not in trusted_real_dirs:
            return None, (
                "documented route binary `%s` resolves to `%s`, which is "
                "outside the trusted system directories (%s); route proof "
                "refused" % (word, resolved, ", ".join(trusted_dirs))
            )
        try:
            mode = os.stat(resolved).st_mode
        except OSError as exc:
            return None, "documented route binary `%s` cannot be read: %s" % (word, exc)
        if not stat.S_ISREG(mode):
            return None, "documented route binary `%s` is not a regular file" % word
        if os.access(resolved, os.W_OK):
            return None, (
                "trusted route binary `%s` is writable by the current user" % resolved
            )
        return resolved, None
    verb = word
    for directory in trusted_dirs:
        candidate = os.path.join(directory, verb)
        resolved = os.path.realpath(candidate)
        if os.path.dirname(resolved) not in trusted_real_dirs:
            continue
        try:
            mode = os.stat(resolved).st_mode
        except OSError:
            continue
        if not stat.S_ISREG(mode):
            continue
        if os.access(resolved, os.W_OK):
            return None, "trusted route binary `%s` is writable by the current user" % resolved
        return resolved, None
    return None, (
        "no trusted non-writable `%s` binary exists in %s; route proof refused"
        % (verb, ", ".join(trusted_dirs))
    )


def _file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def _shell_quote(value):
    if re.fullmatch(r"[A-Za-z0-9_./:=-]+", value):
        return value
    return "'%s'" % value.replace("'", "'\\''")


def deletion_accounting(before, loaded, archive, rows):
    fallback_keys = occurrence_keys([entry["heading"] for entry in before["entries"]])
    before_keys = {
        entry.get("key", fallback_key)
        for entry, fallback_key in zip(before["entries"], fallback_keys)
    }
    unknown = [row for row in rows if row["key"] not in before_keys]
    known = [row for row in rows if row["key"] in before_keys]
    before_counts = Counter(entry["norm"] for entry in before["entries"])
    after_counts = Counter(entry["norm"] for entry in loaded["entries"])
    if archive:
        after_counts.update(entry["norm"] for entry in archive["entries"])
    declared = Counter(
        row["norm"] for row in known if row["verdict"] in ("delete", "fold")
    )
    observed = Counter({
        norm: max(0, count - after_counts[norm])
        for norm, count in before_counts.items()
    })
    undeclared = []
    ghosts = []
    for norm, count in before_counts.items():
        missing = max(0, observed[norm] - declared[norm])
        undeclared.extend(
            "%s#%d" % (norm, ordinal)
            for ordinal in range(count - missing + 1, count + 1)
        )
        extra = max(0, declared[norm] - observed[norm])
        declarations = [
            row for row in known
            if row["norm"] == norm and row["verdict"] in ("delete", "fold")
        ]
        ghosts.extend(declarations[-extra:] if extra else [])
    return before_keys, known, unknown, undeclared, ghosts


def cmd_check(args):
    failures = []
    warnings = []

    before = load_baseline(args)
    shape = resolve_baseline_shape(args, before)

    if shape == "shared" and before["mode"] == "pair":
        die(
            "refused: a pair baseline with --shape shared.\n"
            "  A shared tracked file has no archive to pair it with. Its detail "
            "moves to the file that already owns it and an inline stub points "
            "there, so its before-state is always the one file.",
            1,
        )
    if shape == "shared" and args.archive:
        die(
            "refused: --archive with --shape shared.\n"
            "  A shared tracked file is under a one-owner contract. Its detail "
            "moves to the file that already owns it and an inline stub points "
            "there. An archive of its prose would be a second owner, which is "
            "the defect this exercise exists to prevent.",
            1,
        )
    if shape == "private" and not args.archive:
        die(
            "refused: shape private with no --archive.\n"
            "  A private knowledge file splits into a loaded half and a real "
            "archive file. Without one there is nothing to prove reachable.",
            1,
        )

    meta, rows = read_worksheet(args.worksheet)
    if not rows:
        die("worksheet %s has no entry blocks" % args.worksheet, 1)

    vocab = PRIVATE_VERDICTS if shape == "private" else SHARED_VERDICTS
    loaded_level, archive_level = baseline_levels(before)
    loaded = file_facts(args.loaded, loaded_level)
    loaded_text = read_text(args.loaded)
    archive = None
    archive_text = ""
    if args.archive:
        archive = file_facts(args.archive, archive_level)
        archive_text = read_text(args.archive)
        orphaned = orphan_nested_headings(archive_text, archive["level"])
        if orphaned:
            failures.append(
                "%d nested archive headings are orphaned outside every level-%d "
                "entry: %s"
                % (len(orphaned), archive["level"], ", ".join(orphaned[:8]))
            )

    before_keys, known_rows, unknown_rows, undeclared_loss, ghost_rows = (
        deletion_accounting(before, loaded, archive, rows)
    )
    before_counts = Counter(e["norm"] for e in before["entries"])
    loaded_counts = Counter(e["norm"] for e in loaded["entries"])
    archive_counts = Counter(e["norm"] for e in archive["entries"]) if archive else Counter()
    after_counts = loaded_counts + archive_counts
    # A rule extracted from a split rarely keeps its own entry heading: it
    # becomes a bullet under a broader heading that already exists. So the
    # "where did the rule land" and "did this heading vanish" questions are
    # asked against EVERY heading in the file, not only the entry level.
    loaded_all = {norm_heading(t) for _, t in all_headings(loaded_text)}
    archive_all = {norm_heading(t) for _, t in all_headings(archive_text)} if archive else set()
    after_all_norms = loaded_all | archive_all

    print("=== fm-curate-knowledge check ===")
    print("shape          %s" % shape)
    print("baseline       %s (%s)" % (before["path"], before["mode"]))
    print("loaded half    %s" % loaded["path"])
    print("archive        %s" % (archive["path"] if archive else "(none - shared shape)"))
    print("worksheet      %s (%d verdicts)" % (args.worksheet, len(rows)))
    print("")

    # --- 1. verdict legality -------------------------------------------------
    for row in key_conflicts(rows):
        failures.append(key_conflict_message(row))
    by_key = {}
    for row in rows:
        verdict = row["verdict"].strip()
        if verdict not in vocab:
            failures.append(
                "entry %s `%s`: verdict `%s` is not valid for shape %s (%s)"
                % (row["n"], row["heading"][:60], verdict, shape, "|".join(vocab))
            )
            continue
        if verdict != DEFAULT_VERDICT[shape] and len(row["why"]) < WHY_FLOOR:
            failures.append(
                "entry %s `%s`: verdict `%s` deviates from the default `%s` "
                "with a why of %d characters (floor %d)"
                % (
                    row["n"],
                    row["heading"][:60],
                    verdict,
                    DEFAULT_VERDICT[shape],
                    len(row["why"]),
                    WHY_FLOOR,
                )
            )
        if row["key"] in by_key:
            failures.append("worksheet repeats occurrence key `%s`" % row["key"])
        by_key[row["key"]] = row

    # Verdicts are owed for the before-LOADED half's entries. On a pair baseline
    # the existing archive's entries are accounted for by presence, not by
    # judgement: a re-run curates what accumulated in the loaded half, and
    # demanding a verdict per archive entry would price every re-run at the whole
    # archive.
    undeclared = sorted(before["verdict_keys"] - set(by_key))
    if undeclared:
        failures.append(
            "%d baseline entries carry no verdict: %s"
            % (len(undeclared), ", ".join(undeclared[:5]))
        )
    for row in unknown_rows:
        failures.append(
            "worksheet occurrence key `%s` is absent from the baseline snapshot"
            % row["key"]
        )

    # --- 2. heading counts must fall ----------------------------------------
    before_all = before["heading_count_all"]
    before_loaded_all = before["loaded_heading_count"]
    after_all = loaded["heading_count_all"] + (
        archive["heading_count_all"] if archive else 0
    )
    print("HEADINGS  before %d  ->  after %d (loaded %d + archive %d)" % (
        before_all,
        after_all,
        loaded["heading_count_all"],
        archive["heading_count_all"] if archive else 0,
    ))
    if before["mode"] == "pair":
        print(
            "          the before-state is the pair: loaded %d + archive %d"
            % (before_loaded_all, before_all - before_loaded_all)
        )
        print(
            "          entry level per half: loaded %d, archive %d"
            % (loaded_level, archive_level)
        )
    # The two shapes fail differently, so they are gated differently.
    #
    # private: the total must FALL. Splitting is heading-neutral - the heading
    #   leaves the loaded half and lands in the archive - so the only things
    #   that move this number are folds and deletions. That is the point: on
    #   2026-08-16 nothing was folded and the number went 232 -> 252 while the
    #   audit's verdict was "the split executed, nothing was curated".
    #
    # shared: a stub KEEPS its heading by design - the pointer is what stays
    #   behind. Demanding a fall here would push a curator toward merging
    #   sections, which is not what a one-owner prune is. The equivalent gate
    #   is that headings must not RISE and the file must actually get smaller,
    #   because a stub longer than the detail it replaced has pruned nothing.
    if shape == "private":
        if after_all >= before_all:
            failures.append(
                "TOTAL heading count did not fall: %d -> %d. Moving entries "
                "whole from one file to another leaves the total flat; that is "
                "the split executing while nothing is curated."
                % (before_all, after_all)
            )
        if loaded["heading_count_all"] >= before_loaded_all:
            failures.append(
                "loaded-half heading count did not fall: %d -> %d"
                % (before_loaded_all, loaded["heading_count_all"])
            )
    else:
        if loaded["heading_count_all"] > before_loaded_all:
            failures.append(
                "heading count rose: %d -> %d. A prune does not add sections."
                % (before_loaded_all, loaded["heading_count_all"])
            )

    print(
        "BYTES     before %d  ->  loaded %d (%s of the original still loads)"
        % (before["bytes"], loaded["bytes"], pct(loaded["bytes"], before["bytes"]))
    )
    if loaded["bytes"] >= before["bytes"]:
        failures.append(
            "the loaded half did not get smaller: %d -> %d bytes. Startup cost "
            "is what this exercise spends, and it did not fall."
            % (before["bytes"], loaded["bytes"])
        )

    # --- 3. every entry deletion is declared --------------------------------
    if undeclared_loss:
        failures.append(
            "%d entries disappeared with no verdict accounting for them: %s"
            % (len(undeclared_loss), ", ".join(undeclared_loss[:8]))
        )
    ghost_keys = {row["key"] for row in ghost_rows}

    # --- 4. per-verdict placement -------------------------------------------
    verdict_counts = Counter((row["norm"], row["verdict"]) for row in known_rows)
    for norm in before_counts:
        if verdict_counts[(norm, "hot")] > loaded_counts[norm]:
            failures.append(
                "`%s` has %d hot verdicts but only %d loaded occurrences"
                % (norm, verdict_counts[(norm, "hot")], loaded_counts[norm])
            )
        if verdict_counts[(norm, "cold")] > archive_counts[norm]:
            failures.append(
                "`%s` has %d cold verdicts but only %d archive occurrences"
                % (norm, verdict_counts[(norm, "cold")], archive_counts[norm])
            )
    for key, row in sorted(by_key.items()):
        if key not in before_keys:
            continue
        verdict = row["verdict"]
        in_loaded = loaded_counts[row["norm"]] > 0
        in_archive = archive_counts[row["norm"]] > 0
        if verdict == "split":
            # A split ran in one of two directions and both are real: either the
            # heading moved to the archive and its rule became a bullet under a
            # loaded heading, or the heading stayed loaded and its incident was
            # lifted out under an archive heading. What must be true either way
            # is that BOTH halves landed somewhere nameable. Requiring one fixed
            # direction would reject a correct curation, which is worse than a
            # vague `why`: a rejected curation gets undone, a vague why gets read.
            kept = in_loaded or _fold_target_found(row["why"], loaded_all)
            shed = in_archive or _fold_target_found(row["why"], archive_all)
            if not kept:
                failures.append(
                    "`%s` is verdict split but the rule landed nowhere: the "
                    "heading is gone from the loaded half and the why names no "
                    "loaded heading the rule now lives under"
                    % row["heading"][:60]
                )
            if not shed:
                failures.append(
                    "`%s` is verdict split but nothing of it reached the "
                    "archive: the heading is not there and the why names no "
                    "archive heading the incident went under"
                    % row["heading"][:60]
                )
        elif verdict == "hot":
            pass
        elif verdict == "cold":
            pass
        elif verdict == "stub":
            if not in_loaded:
                failures.append(
                    "`%s` is verdict stub but its heading is gone from the file; "
                    "a stub leaves the pointer behind" % row["heading"][:60]
                )
            owner = _owner_path_in(row["why"], args.root)
            if owner is None:
                failures.append(
                    "`%s` is verdict stub but its why names no existing owner "
                    "path under %s" % (row["heading"][:60], args.root)
                )
            elif os.path.basename(owner) not in loaded_text:
                failures.append(
                    "`%s` is verdict stub with owner %s, but the file never "
                    "points at it" % (row["heading"][:60], owner)
                )
        elif verdict == "fold":
            if key in ghost_keys:
                failures.append(
                    "phantom fold: `%s` is still present in the loaded half or archive"
                    % row["heading"][:60]
                )
            if not _fold_target_found(row["why"], after_all_norms):
                failures.append(
                    "`%s` is verdict fold but its why names no surviving "
                    "heading it merged into" % row["heading"][:60]
                )
        elif verdict == "delete":
            if key in ghost_keys:
                failures.append(
                    "phantom deletion: `%s` is still present in the loaded half or archive"
                    % row["heading"][:60]
                )
            if len(row["why"]) < WHY_FLOOR:
                failures.append(
                    "`%s` is verdict delete with a why of %d characters; "
                    "judgement archives, only proof deletes"
                    % (row["heading"][:60], len(row["why"]))
                )

    # --- 5. no invented archive content -------------------------------------
    if archive:
        invented = sorted((archive_counts - before_counts).elements())
        if invented:
            warnings.append(
                "%d archive headings were not in the baseline: %s"
                % (len(invented), ", ".join(invented[:5]))
            )

    # --- 6. the route back lives in the loaded half, and it runs -------------
    if archive:
        print("")
        print("ROUTE BACK")
        rel = os.path.basename(archive["path"])
        commands = []
        if rel not in loaded_text:
            failures.append(
                "the loaded half never names %s. The route back must live "
                "INSIDE the loaded half - it is the only part read." % rel
            )
            print("  MISSING: %s is not named anywhere in the loaded half" % rel)
        else:
            print("  the loaded half names %s" % rel)
            commands = route_commands(loaded_text, archive["path"])
            if not commands:
                failures.append(
                    "the loaded half names %s but hands the reader no runnable "
                    "search over it. A filename is a location, not a route." % rel
                )
                print("  MISSING: no runnable search command (%s)" % ", ".join(ROUTE_VERBS))
            else:
                print("  it hands the reader %d documented search(es):" % len(commands))
                for command in commands[:3]:
                    print("    %s" % command[:150])

        print("")
        print("COMPLETE ROUTE ASSERTION")
        if not archive["entries"]:
            failures.append(
                "the archive holds no entries at level %d, so the route has "
                "nothing to reach and a proof over it would assert nothing"
                % archive["level"]
            )
            print("  the archive holds no level-%d entries to reach" % archive["level"])
        # Every documented search this guard can execute is proved, in whatever
        # order the curator wrote them: proving only the first enforces an order
        # nobody agreed to and refuses the index route this project itself pairs
        # with a `sed` read step. A command the guard cannot execute lands in
        # one of two places rather than being dropped, because a report that
        # quietly omits something is the defect this driver exists to catch: a
        # recognised read-only form is reported as supplementary guidance, and
        # every other form FAILS. Every provable search must run and return
        # results, and at least one must be a heading index reaching every
        # archived entry.
        provable = []
        for command in commands:
            argv = command_argv(command) or []
            if argv and os.path.basename(argv[0]) in ROUTE_VERBS:
                provable.append(command)
                continue
            unrecognised = guidance_form_error(command)
            if unrecognised:
                print("  UNRECOGNISED COMMAND DOCUMENTED: %s" % command[:150])
                failures.append(
                    "the loaded half documents a command this guard cannot "
                    "recognise as read-only: `%s` - %s. data/ is not "
                    "version-controlled, so a reader who follows it could "
                    "destroy a body that cannot be recovered"
                    % (command[:120], unrecognised)
                )
                continue
            print("  NOT PROVABLE BY THIS GUARD: %s" % command[:150])
            print(
                "    route command `%s` cannot be proven non-writing; "
                "document the route with grep or rg. Recognised as a read-only "
                "form and read as supplementary guidance, never executed here."
                % argv[0]
            )
        if commands and not provable:
            failures.append(
                "no documented search is inside the provable interface (%s), so "
                "nothing about the archive's reachability was proven"
                % ", ".join(ROUTE_VERBS)
            )
        complete_routes = 0
        index_routes = 0
        executed_routes = 0
        incomplete_routes = []
        for command in provable:
            status, transcript, missing, result_message = prove_route(
                command,
                args.home,
                archive["path"],
                archive["entries"],
                args.prove_route,
            )
            print("  %s" % command[:150])
            print("    %s" % result_message)
            print("PRINTED EXAMPLE (%d output lines maximum)" % args.prove_route)
            for line in transcript:
                print(line)
            if status == "complete":
                complete_routes += 1
                index_routes += 1
                executed_routes += 1
            elif status == "incomplete":
                index_routes += 1
                executed_routes += 1
                incomplete_routes.append((result_message, missing))
            elif status == "results":
                executed_routes += 1
            else:
                # The reason travels with the FAIL line. A refusal here is the
                # most security-relevant thing this program says, and an
                # operator reading the failures must not have to go looking for
                # why it refused.
                failures.append("documented route failed: %s" % result_message)
        if provable and not complete_routes:
            for result_message, missing in incomplete_routes:
                detail = "; unreachable: %s" % ", ".join(missing[:8]) if missing else ""
                failures.append(
                    "documented route failed: %s%s" % (result_message, detail)
                )
            # Counted from what actually RAN, never from what was documented. A
            # refused route never ran, and saying none of the searches was an
            # index directly beneath the refusal that rejected one for a
            # different reason is a diagnostic contradicting the line above it.
            if executed_routes and not index_routes:
                failures.append(
                    "no documented search is a heading index over the archive, "
                    "so completeness was never established: %d search(es) ran "
                    "and returned results, none of them an index"
                    % executed_routes
                )

    # --- verdict --------------------------------------------------------------
    print("")
    for warning in warnings:
        print("WARN  %s" % warning)
    if failures:
        print("")
        for failure in failures:
            print("FAIL  %s" % failure)
        print("")
        print("CHECK FAILED: %d finding(s). This is a failed prune." % len(failures))
        return 1
    print(
        "CHECK PASSED: headings %d -> %d, bytes %d -> %d, every entry deletion is "
        "declared%s."
        % (
            before_all,
            after_all if archive else loaded["heading_count_all"],
            before["bytes"],
            loaded["bytes"],
            ", and the archive is reachable from the loaded half" if archive else "",
        )
    )
    return 0


def _owner_path_in(why, root):
    """First path-looking token in `why` that exists under the code root."""
    for token in re.findall(r"[A-Za-z0-9_./-]+\.(?:md|sh|py|yaml|yml|json)", why):
        candidate = token if os.path.isabs(token) else os.path.join(root, token)
        if os.path.exists(candidate):
            return token
    return None


def _fold_target_found(why, norms):
    """Does `why` name a heading that survived?

    Matched on word boundaries so a short but real heading like `Bridge` is
    still nameable, while a fragment inside a longer word is not a naming. A
    heading longer than 40 characters may be named by its first 40, so a
    curator is not made to paste a whole title back. This deliberately errs
    toward accepting: a false accept costs a vague `why`, while a false reject
    blocks a correct curation, and only one of those is recoverable by reading.
    """
    lowered = norm_heading(why)
    for norm in norms:
        if len(norm) < 3:
            continue
        for candidate in {norm, _naming_prefix(norm)}:
            if len(candidate) < 3:
                continue
            if re.search(r"(?<!\w)%s(?!\w)" % re.escape(candidate), lowered):
                return True
    return False


def _naming_prefix(norm, limit=40):
    """The longest whole-word prefix of a heading that fits in `limit`.

    Truncating mid-word produces a candidate that can never match on a word
    boundary, which silently turns "name the heading you folded into" into
    "paste the whole title verbatim, parenthetical date included".
    """
    if len(norm) <= limit:
        return norm
    words = norm.split(" ")
    out = []
    for word in words:
        nxt = " ".join(out + [word])
        if out and len(nxt) > limit:
            break
        out.append(word)
    return " ".join(out) if len(out) >= 3 else norm


# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------


def cmd_report(args):
    before = load_baseline(args)
    label, total, rows, notes = denominator(args)

    loaded_level, archive_level = baseline_levels(before)
    loaded = file_facts(args.loaded, loaded_level)
    archive = file_facts(args.archive, archive_level) if args.archive else None

    _meta, wrows = read_worksheet(args.worksheet)
    conflicts = key_conflicts(wrows)
    if conflicts:
        die(
            "report refused: %s" % "; ".join(key_conflict_message(row) for row in conflicts),
            1,
        )
    _keys, _known, unknown, undeclared, ghosts = deletion_accounting(
        before, loaded, archive, wrows
    )
    if unknown:
        die(
            "report refused: worksheet occurrence key absent from baseline: %s"
            % ", ".join(row["key"] for row in unknown),
            1,
        )
    if undeclared:
        die(
            "report refused: undeclared disappearance: %s"
            % ", ".join(undeclared),
            1,
        )
    if ghosts:
        die(
            "report refused: phantom delete or fold still present: %s"
            % ", ".join(row["heading"] for row in ghosts),
            1,
        )

    before_bytes = before["bytes"]
    loaded_bytes = loaded["bytes"]
    archive_bytes = archive["bytes"] if archive else 0

    # Which surface a share is against depends on where the loaded half IS. The
    # workflow this skill teaches stages the new pair outside the home and moves
    # it in only after the check passes, so a run's --loaded is usually a file
    # no surface contains. Reporting its share against the measured surface
    # would price a state that does not exist, which is the same offence as
    # printing a line count.
    # A captured digest is a byte size with no file list, so membership in it
    # cannot be measured. Concluding STAGED from an empty row list would state a
    # result the program never took a reading for, which is the offence this
    # driver exists to refuse. Unknown is reported as unknown.
    membership_measurable = bool(rows)
    surface_paths = {os.path.realpath(row[1]) for row in rows if row[3]}
    loaded_in_place = os.path.realpath(args.loaded) in surface_paths
    baseline_path = before.get("loaded_path") or before["path"]
    baseline_in_place = os.path.realpath(baseline_path) in surface_paths
    if not membership_measurable:
        before_total = total
        after_total = total
    elif loaded_in_place:
        before_total = total - loaded_bytes + before_bytes
        after_total = total
    else:
        before_total = total
        after_total = (
            total - before_bytes + loaded_bytes if baseline_in_place
            else total + loaded_bytes
        )

    print("=== fm-curate-knowledge report ===")
    print("baseline       %s (%s)" % (before["path"], before["mode"]))
    print("denominator    %s" % label)
    for note in notes:
        print("  note: %s" % note)
    if not membership_measurable:
        print(
            "  note: whether the loaded half is part of this denominator is "
            "UNMEASURED - a captured digest carries no file list, so both "
            "shares below are against the digest as captured, and neither is "
            "a projection of any other state"
        )
    elif not loaded_in_place:
        print(
            "  note: the loaded half is STAGED - %s is in no measured surface, "
            "so its share below is a PROJECTION of the surface after the pair "
            "is moved into place, not a state that exists yet"
            % os.path.realpath(args.loaded)
        )
    if membership_measurable and not baseline_in_place:
        print(
            "  note: the baseline file %s is not part of the measured surface "
            "either, so this run is a rehearsal against copies" % baseline_path
        )
    print("")
    print("STARTUP COST")
    print(
        "  before   %8d B   %7s of a %d B surface"
        % (before_bytes, pct(before_bytes, before_total), before_total)
    )
    print(
        "  after    %8d B   %7s of a %d B surface%s"
        % (
            loaded_bytes,
            pct(loaded_bytes, after_total),
            after_total,
            ""
            if loaded_in_place or not membership_measurable
            else "   (PROJECTION, not yet in place)",
        )
    )
    delta = loaded_bytes - before_bytes
    print(
        "  change   %+8d B   %s of the original still loads"
        % (delta, pct(loaded_bytes, before_bytes))
    )
    if archive:
        print(
            "  archived %8d B   not loaded at session start"
            % archive_bytes
        )
        # Stated as plain arithmetic, not as "how much survived": a curation
        # that writes fresh summary prose over a fully retained archive lands
        # above 100 percent, and a survival claim would be false there.
        kept = loaded_bytes + archive_bytes
        print(
            "  retained %8d B   loaded + archived, against %d B before (%s)"
            % (kept, before_bytes, pct(kept, before_bytes))
        )

    print("")
    print("HEADINGS")
    after_all = loaded["heading_count_all"] + (archive["heading_count_all"] if archive else 0)
    print(
        "  before %d  ->  after %d  (loaded %d + archive %d)"
        % (
            before["heading_count_all"],
            after_all,
            loaded["heading_count_all"],
            archive["heading_count_all"] if archive else 0,
        )
    )
    print(
        "  entries: %d -> %d loaded at level %d, %d archived at level %d"
        % (
            len(before["entries"]),
            len(loaded["entries"]),
            loaded["level"],
            len(archive["entries"]) if archive else 0,
            archive["level"] if archive else loaded["level"],
        )
    )

    counts = {}
    for row in wrows:
        counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1
    print("")
    print("VERDICTS")
    for verdict in sorted(counts, key=lambda v: -counts[v]):
        print("  %-8s %d" % (verdict, counts[verdict]))

    deletions = [r for r in wrows if r["verdict"] == "delete"]
    print("")
    print("DELETION LEDGER (%d)" % len(deletions))
    if not deletions:
        print("  none")
    for row in deletions:
        print("  - %s" % row["heading"])
        print("    evidence: %s" % row["why"])

    folds = [r for r in wrows if r["verdict"] == "fold"]
    print("")
    print("FOLDED INTO ANOTHER ENTRY (%d)" % len(folds))
    if not folds:
        print("  none")
    for row in folds:
        print("  - %s" % row["heading"])
        print("    into: %s" % row["why"])
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def default_root():
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def add_common(parser):
    parser.add_argument("--home", default=None, help="operational home holding data/ and config/")
    parser.add_argument("--root", default=None, help="code root holding bin/, AGENTS.md, roles/")
    parser.add_argument("--level", type=int, default=None, help="entry heading level")
    parser.add_argument(
        "--shape",
        choices=("private", "shared"),
        default=None,
        help="shape for a file with no baseline or Git classification",
    )
    parser.add_argument("--against", default="startup", help="`startup` or a captured digest file")


def add_pair_baseline(parser):
    """The before-state of a re-run, whose archive already exists."""
    parser.add_argument(
        "--before-loaded",
        default=None,
        help="baseline loaded half, for a re-run against an existing archive",
    )
    parser.add_argument(
        "--before-archive",
        default=None,
        help="baseline archive, paired with --before-loaded",
    )


def resolve_paths(args):
    args.home = os.path.abspath(args.home or os.environ.get("FM_HOME") or default_root())
    if args.root:
        args.root = os.path.abspath(args.root)
    elif os.path.isfile(os.path.join(args.home, "bin", "fm-session-start.sh")):
        args.root = args.home
    else:
        args.root = default_root()


def main(argv):
    parser = argparse.ArgumentParser(
        prog="fm-curate-knowledge.py",
        description="Measure, inventory, check, and report a knowledge-file prune.",
    )
    sub = parser.add_subparsers(dest="command")

    p_measure = sub.add_parser("measure", help="bytes, headings, per-entry sizes, share")
    add_common(p_measure)
    p_measure.add_argument("files", nargs="*", help="files to measure (default: the whole surface)")
    p_measure.add_argument("--top", type=int, default=10, help="how many largest entries to list")
    p_measure.add_argument("--save", default=None, help="write a baseline snapshot JSON")
    p_measure.add_argument("--json", action="store_true")
    p_measure.add_argument("--lines", action="store_true", help=argparse.SUPPRESS)
    p_measure.set_defaults(func=cmd_measure)

    p_inv = sub.add_parser("inventory", help="emit a verdict worksheet")
    add_common(p_inv)
    p_inv.add_argument("file")
    p_inv.add_argument("--out", required=True, help="worksheet path to write")
    p_inv.set_defaults(func=cmd_inventory)

    p_check = sub.add_parser("check", help="gate a prune; non-zero on failure")
    add_common(p_check)
    p_check.add_argument("--before", required=True, help="baseline snapshot JSON")
    p_check.add_argument("--before-file", default=None, help="which snapshot file is the baseline")
    add_pair_baseline(p_check)
    p_check.add_argument("--worksheet", required=True)
    p_check.add_argument("--loaded", required=True)
    p_check.add_argument("--archive", default=None)
    p_check.add_argument("--prove-route", type=int, default=3, help="archived facts to actually recover")
    p_check.set_defaults(func=cmd_check)

    p_report = sub.add_parser("report", help="before/after bytes, share, deletion ledger")
    add_common(p_report)
    p_report.add_argument("--before", required=True)
    p_report.add_argument("--before-file", default=None)
    add_pair_baseline(p_report)
    p_report.add_argument("--loaded", required=True)
    p_report.add_argument("--archive", default=None)
    # Required, not optional: the deletion ledger is the only record a deleted
    # entry ever gets, and a report that could be produced without one reports
    # everything except the part the captain is entitled to audit.
    p_report.add_argument("--worksheet", required=True)
    p_report.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help()
        return 2
    resolve_paths(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
