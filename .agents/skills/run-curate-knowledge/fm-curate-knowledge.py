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
                                worksheet declared. An unlisted deletion cannot
                                survive a run.
  * the archive went dark    -> `check` requires the route back to live INSIDE
                                the loaded half, requires that route to be a
                                runnable search command, and then RUNS it
                                against sampled archived headings and prints
                                the output. The route is proved, not asserted.

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
Shape is auto-detected from git tracking and can be forced with --shape. The
verdict vocabularies do not overlap: `cold` and `split` are refused on a shared
file, `stub` is the shared file's default, and passing --archive with
--shape shared is refused outright.

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
                              --loaded FILE [--archive FILE] [options]
      The gate. Exits non-zero on a failed prune.

  fm-curate-knowledge.py report --before <snapshot.json> --loaded FILE
                              [--archive FILE] [--worksheet <w.md>] [options]
      Before/after in bytes and share, plus the deletion ledger with evidence.

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
error. `measure` and `report` are reporting commands and exit 0 unless a path
is unreadable; `check` is a gate and its exit status is the verdict.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*$")

# bin/fm-session-start.sh step 6 prints each context file through this helper.
# Extracting the calls keeps that script the single owner of what loads.
DIGEST_CALL_RE = re.compile(r'print_file_or_absent\s+"\$DATA/([^"]+)"')

# A route back is only a route if it can be run. These are the read-only search
# verbs a loaded half may hand a reader; anything else is prose about the
# archive rather than a way into it.
ROUTE_VERBS = ("grep", "rg", "sed", "awk", "less", "fm-curate-knowledge.py")

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
    for index, level_at, heading in entry_starts:
        following = [b for b in boundaries if b > index]
        end = following[0] if following else len(lines)
        body = "".join(lines[index:end])
        entries.append(
            {
                "heading": heading,
                "norm": norm_heading(heading),
                "level": level_at,
                "line": index + 1,
                "bytes": len(body.encode("utf-8")),
            }
        )
    preamble = sum(len(line.encode("utf-8")) for line in lines[: entry_starts[0][0]])
    return preamble, entries


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
    """git-tracked under the code root -> shared; otherwise private.

    Tracking is the real signal: shared tracked material is exactly the
    material other homes receive, and it is exactly the material under the
    one-owner contract that forbids an archive.
    """
    try:
        result = subprocess.run(
            ["git", "-C", root, "ls-files", "--error-unmatch", os.path.abspath(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return "private"
    return "shared" if result.returncode == 0 else "private"


def resolve_shape(args, path):
    if args.shape:
        return args.shape
    return detect_shape(path, args.root)


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
            "heading: {heading}\n"
            "bytes: {bytes}\n"
            "share_of_file: {share}\n"
            "verdict: {default}\n"
            "why:\n\n".format(
                n=index,
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
            current = {"n": raw.split()[-1], "heading": "", "verdict": "", "why": ""}
            key = None
            continue
        if current is None:
            continue
        match = re.match(r"^([a-z_]+):\s*(.*)$", raw)
        if match and match.group(1) in (
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
    for row in rows:
        row["norm"] = norm_heading(row["heading"])
    return meta, rows


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

    print("DENOMINATOR: %s = %d bytes" % (label, total))
    for row_label, path, size, present, source in rows:
        print(
            "  %-28s %10s  %7s  %s"
            % (
                row_label,
                ("%d B" % size) if present else "ABSENT",
                pct(size, total) if present else "-",
                source,
            )
        )
    for note in notes:
        print("  note: %s" % note)
    print("")

    for target in targets:
        if not os.path.isfile(target):
            die("not a readable file: %s" % target, 1)
        facts = file_facts(target, args.level)
        shape = resolve_shape(args, target)
        facts["shape"] = shape
        payload["files"][facts["path"]] = facts

        print("FILE: %s" % target)
        print("  shape             %s" % shape)
        print(
            "  bytes             %d  (%s of the %s)"
            % (facts["bytes"], pct(facts["bytes"], total), label)
        )
        print(
            "  headings          %d total, %d at level %d (the entry level)"
            % (facts["heading_count_all"], len(facts["entries"]), facts["level"])
        )
        print(
            "  preamble          %d bytes before the first entry"
            % facts["preamble_bytes"]
        )
        if facts["entries"]:
            sizes = sorted(e["bytes"] for e in facts["entries"])
            middle = sizes[len(sizes) // 2]
            print(
                "  entry bytes       median %d, largest %d, smallest %d"
                % (middle, sizes[-1], sizes[0])
            )
            top = sorted(facts["entries"], key=lambda e: -e["bytes"])[: args.top]
            print("  largest %d entries:" % len(top))
            for entry in top:
                print(
                    "    %8d B  %6s of file  %6s of surface  %s"
                    % (
                        entry["bytes"],
                        pct(entry["bytes"], facts["bytes"]),
                        pct(entry["bytes"], total),
                        entry["heading"],
                    )
                )
        print("")

    if args.save:
        payload["denominator"]["rows"] = [
            {"label": r[0], "path": r[1], "bytes": r[2], "present": r[3]} for r in rows
        ]
        with open(args.save, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
        print("SNAPSHOT: wrote %s" % args.save)

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


def route_commands(loaded_text, archive_path):
    """Lines in the loaded half that are a runnable search over the archive."""
    base = os.path.basename(archive_path)
    found = []
    for line in loaded_text.splitlines():
        if base not in line:
            continue
        if any(verb in line for verb in ROUTE_VERBS):
            found.append(line.strip().lstrip("$").strip().strip("`"))
    return found


def prove_route(archive_path, headings, sample):
    """Actually recover archived facts. Returns (ok, transcript lines)."""
    lines = []
    ok = True
    if not headings:
        return True, ["  (archive has no entries to recover)"]
    step = max(1, len(headings) // sample) if sample else 1
    chosen = headings[::step][:sample]
    for heading in chosen:
        command = ["grep", "-n", "-F", "--", heading, archive_path]
        lines.append("  $ %s" % " ".join(_shell_quote(part) for part in command))
        result = subprocess.run(
            command, capture_output=True, text=True, check=False
        )
        out = result.stdout.strip().splitlines()
        if result.returncode != 0 or not out:
            ok = False
            lines.append("    NO HIT - this archived fact is unrecoverable")
            continue
        for line in out[:2]:
            lines.append("    %s" % line[:160])
    return ok, lines


def _shell_quote(value):
    if re.fullmatch(r"[A-Za-z0-9_./:=-]+", value):
        return value
    return "'%s'" % value.replace("'", "'\\''")


def cmd_check(args):
    failures = []
    warnings = []

    _snap, before = load_snapshot(args.before, args.before_file)
    shape = args.shape or before.get("shape") or detect_shape(args.loaded, args.root)

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
    loaded = file_facts(args.loaded, args.level or before.get("level"))
    loaded_text = read_text(args.loaded)
    archive = None
    archive_text = ""
    if args.archive:
        archive = file_facts(args.archive, args.level or before.get("level"))
        archive_text = read_text(args.archive)

    before_norms = {e["norm"] for e in before["entries"]}
    loaded_norms = {e["norm"] for e in loaded["entries"]}
    archive_norms = {e["norm"] for e in archive["entries"]} if archive else set()
    after_norms = loaded_norms | archive_norms
    # A rule extracted from a split rarely keeps its own entry heading: it
    # becomes a bullet under a broader heading that already exists. So the
    # "where did the rule land" and "did this heading vanish" questions are
    # asked against EVERY heading in the file, not only the entry level.
    loaded_all = {norm_heading(t) for _, t in all_headings(loaded_text)}
    archive_all = {norm_heading(t) for _, t in all_headings(archive_text)} if archive else set()
    after_all_norms = loaded_all | archive_all

    print("=== fm-curate-knowledge check ===")
    print("shape          %s" % shape)
    print("baseline       %s" % before["path"])
    print("loaded half    %s" % loaded["path"])
    print("archive        %s" % (archive["path"] if archive else "(none - shared shape)"))
    print("worksheet      %s (%d verdicts)" % (args.worksheet, len(rows)))
    print("")

    # --- 1. verdict legality -------------------------------------------------
    by_norm = {}
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
        by_norm[row["norm"]] = row

    undeclared = sorted(before_norms - set(by_norm))
    if undeclared:
        failures.append(
            "%d baseline entries carry no verdict: %s"
            % (len(undeclared), ", ".join(undeclared[:5]))
        )

    # --- 2. heading counts must fall ----------------------------------------
    before_all = before["heading_count_all"]
    after_all = loaded["heading_count_all"] + (
        archive["heading_count_all"] if archive else 0
    )
    print("HEADINGS  before %d  ->  after %d (loaded %d + archive %d)" % (
        before_all,
        after_all,
        loaded["heading_count_all"],
        archive["heading_count_all"] if archive else 0,
    ))
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
        if loaded["heading_count_all"] >= before_all:
            failures.append(
                "loaded-half heading count did not fall: %d -> %d"
                % (before_all, loaded["heading_count_all"])
            )
    else:
        if loaded["heading_count_all"] > before_all:
            failures.append(
                "heading count rose: %d -> %d. A prune does not add sections."
                % (before_all, loaded["heading_count_all"])
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

    # --- 3. every deletion is declared --------------------------------------
    vanished = before_norms - after_norms - after_all_norms
    declared_gone = {
        norm for norm, row in by_norm.items() if row["verdict"] in ("delete", "fold")
    }
    undeclared_loss = sorted(vanished - declared_gone)
    if undeclared_loss:
        failures.append(
            "%d entries disappeared with no verdict accounting for them: %s"
            % (len(undeclared_loss), ", ".join(undeclared_loss[:8]))
        )
    ghosts = sorted(declared_gone - vanished)
    if ghosts:
        warnings.append(
            "%d entries were declared deleted or folded but are still present: %s"
            % (len(ghosts), ", ".join(ghosts[:8]))
        )

    # --- 4. per-verdict placement -------------------------------------------
    for norm, row in sorted(by_norm.items()):
        verdict = row["verdict"]
        in_loaded = norm in loaded_norms
        in_archive = norm in archive_norms
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
            if not in_loaded:
                failures.append("`%s` is verdict hot but is not in the loaded half" % row["heading"][:60])
            if in_archive:
                failures.append("`%s` is verdict hot but also appears in the archive" % row["heading"][:60])
        elif verdict == "cold":
            if not in_archive:
                failures.append("`%s` is verdict cold but is not in the archive" % row["heading"][:60])
            if in_loaded:
                failures.append("`%s` is verdict cold but is still in the loaded half" % row["heading"][:60])
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
            if not _fold_target_found(row["why"], after_all_norms):
                failures.append(
                    "`%s` is verdict fold but its why names no surviving "
                    "heading it merged into" % row["heading"][:60]
                )
        elif verdict == "delete":
            if len(row["why"]) < WHY_FLOOR:
                failures.append(
                    "`%s` is verdict delete with a why of %d characters; "
                    "judgement archives, only proof deletes"
                    % (row["heading"][:60], len(row["why"]))
                )

    # --- 5. no invented archive content -------------------------------------
    if archive:
        invented = sorted(archive_norms - before_norms)
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
                print("  it hands the reader %d runnable search(es):" % len(commands))
                for command in commands[:3]:
                    print("    %s" % command[:150])

        print("")
        print("PROOF OF RECOVERY (rule 3: prove the route, do not assert it)")
        headings = [e["heading"] for e in archive["entries"]]
        ok, transcript = prove_route(archive["path"], headings, args.prove_route)
        for line in transcript:
            print(line)
        if not ok:
            failures.append("at least one sampled archived fact could not be recovered")

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
        "CHECK PASSED: headings %d -> %d, bytes %d -> %d, every deletion is "
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
    _snap, before = load_snapshot(args.before, args.before_file)
    label, total, rows, notes = denominator(args)

    loaded = file_facts(args.loaded, args.level or before.get("level"))
    archive = file_facts(args.archive, args.level or before.get("level")) if args.archive else None

    before_bytes = before["bytes"]
    loaded_bytes = loaded["bytes"]
    archive_bytes = archive["bytes"] if archive else 0

    # The denominator moved when the file did. Report the share the loaded half
    # WOULD have had at the old surface size, and the share it has now.
    before_total = total - loaded_bytes + before_bytes

    print("=== fm-curate-knowledge report ===")
    print("denominator    %s" % label)
    for note in notes:
        print("  note: %s" % note)
    print("")
    print("STARTUP COST")
    print(
        "  before   %8d B   %7s of a %d B surface"
        % (before_bytes, pct(before_bytes, before_total), before_total)
    )
    print(
        "  after    %8d B   %7s of a %d B surface"
        % (loaded_bytes, pct(loaded_bytes, total), total)
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
        "  entries at level %d: %d -> %d loaded, %d archived"
        % (
            before["level"],
            len(before["entries"]),
            len(loaded["entries"]),
            len(archive["entries"]) if archive else 0,
        )
    )

    if args.worksheet:
        meta, wrows = read_worksheet(args.worksheet)
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
    parser.add_argument("--shape", choices=("private", "shared"), default=None)
    parser.add_argument("--against", default="startup", help="`startup` or a captured digest file")


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
    p_check.add_argument("--worksheet", required=True)
    p_check.add_argument("--loaded", required=True)
    p_check.add_argument("--archive", default=None)
    p_check.add_argument("--prove-route", type=int, default=3, help="archived facts to actually recover")
    p_check.set_defaults(func=cmd_check)

    p_report = sub.add_parser("report", help="before/after bytes, share, deletion ledger")
    add_common(p_report)
    p_report.add_argument("--before", required=True)
    p_report.add_argument("--before-file", default=None)
    p_report.add_argument("--loaded", required=True)
    p_report.add_argument("--archive", default=None)
    p_report.add_argument("--worksheet", default=None)
    p_report.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help()
        return 2
    resolve_paths(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
