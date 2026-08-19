#!/usr/bin/env python3
"""fm-transcript-reduce.py - build a searchable, redacted derivative of agent
session transcripts.

Two source shapes, one output shape:

  claude  ~/.claude/projects/<project-slug>/**/<session-id>.jsonl
  codex   ~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<id>.jsonl

What survives the reduction (deliberately, and this is the whole honesty of
the artefact):

  * every user and assistant message, VERBATIM
  * every command issued, VERBATIM
  * the first N characters (default 400) of every tool result
  * the first N characters of every reasoning/thinking block
  * a per-session header: id, project, working directory, time span

What never survives: raw tool output past N characters, encrypted reasoning
blobs, file-history snapshots, token accounting, queue/mode bookkeeping.
WHAT NEVER SURVIVED WAS ALSO NEVER SCANNED FOR CREDENTIALS. The derivative is
verified; the discarded remainder is not, and no claim about it is made here.

The redaction is exactly as good as the pattern file and not one bit better.
Patterns live in bin/fm-transcript-patterns/patterns.txt and are NEVER passed on
a command line, because a detector whose patterns are typed into a shell writes
those patterns into the next transcript and poisons every later scan. Every
literal in that file is spelled with a self-breaking character class so the file
does not match itself; keep that spelling, and build test fixtures the same way.

A WRONG --source IS LOUD, NOT SILENT. A Claude-shaped reader returns zero
entries on a Codex rollout and raises nothing at all, which looks exactly like a
session that had nothing in it. So the run pre-flights every input file for its
record shape and refuses before writing anything when the shape disagrees with
--source, and it refuses again afterwards if a whole run produced no entries or
found no input files. An empty archive is never a silent success here.

THE STORE IS COMPRESSED, AND A FULL CONTENT SCAN IS STILL THE INDEX. Each
session is written as one zstd-compressed file, `<session>.txt.zst`, because
ripgrep reads zstd directly with `-z`: the whole store is scanned by content on
every search and no second artefact exists that could disagree with it. An
inverted index is still forbidden here, for the reason it always was - it can go
stale silently.
Compression cannot, because a wrong decompression is an error and not a wrong
answer.

The compressor is the `zstd` binary (FM_ZSTD overrides it for building and
verifying). It is a hard requirement rather than a preference: a run that cannot
compress refuses instead of leaving a store that is half compressed and half
plain, which is exactly the kind of quiet disagreement this archive exists to
avoid.

Usage:
  fm-transcript-reduce.py --source claude|codex --in DIR --out DIR
                          [--patterns FILE] [--truncate 400] [--limit N]
                          [--level 3] [--fold-injected] [--quiet]
  fm-transcript-reduce.py --verify-only --out DIR [--patterns FILE]

Exit status:
  0  built (or verified with zero residual hits)
  2  verification found residual hits, or the input shape disagrees with --source
  3  nothing was read: no input files, or every file yielded zero entries
  4  the compressor is missing, or it failed on a file
"""
import argparse, json, os, re, shutil, subprocess, sys, time
from collections import Counter

# ---------------------------------------------------------------- patterns

def load_patterns(path):
    pats = []
    with open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) != 3:
                sys.exit('patterns.txt:%d: expected 3 tab-separated fields' % lineno)
            cls, flag, rx = parts
            try:
                cre = re.compile(rx)
            except re.error as e:
                sys.exit('patterns.txt:%d: bad regex for %s: %s' % (lineno, cls, e))
            grp = 0 if flag == 'whole' else int(flag[1:])
            pats.append((cls, grp, cre))
    return pats


# values that are named like a credential but are demonstrably not one.
# These holes are deliberate and are named in the report: a variable
# reference, a path, and an already-masked value are worth more as context
# than as a redaction, and masking them would hide provenance for nothing.
_BENIGN_VALUE = re.compile(
    r'''^(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?          # $VAR / ${VAR}
        |[~./][^\s]*                                # a path
        |<[^>]+>                                    # <placeholder>
        |\*{3,}|x{6,}|X{6,}                         # already masked
        |\[REDACTED[^\]]*\]
        |(?:REDACTED|redacted|CHANGEME|changeme|your[_-]?\w+|example|placeholder|null|None|true|false)
        )$''', re.X)


def redact(text, pats, counter):
    """Return (redacted_text, n_redactions). Never returns a matched value."""
    if not text:
        return text, 0
    n = 0
    for cls, grp, cre in pats:
        out = []
        last = 0
        for m in cre.finditer(text):
            s, e = (m.start(grp), m.end(grp)) if grp else (m.start(), m.end())
            if s < 0:
                continue
            if grp:
                val = m.group(grp)
                if _BENIGN_VALUE.match(val):
                    continue
            out.append(text[last:s])
            out.append('[REDACTED %s]' % cls)
            last = e
            n += 1
            counter[cls] += 1
        if out:
            out.append(text[last:])
            text = ''.join(out)
    return text, n


def scan(text, pats):
    """Count hits without producing output. Used for verification."""
    hits = Counter()
    if not text:
        return hits
    for cls, grp, cre in pats:
        for m in cre.finditer(text):
            if grp:
                val = m.group(grp)
                if val is None or _BENIGN_VALUE.match(val):
                    continue
            hits[cls] += 1
    return hits


# ---------------------------------------------------------------- storage

# One session, one compressed file. The extension is what makes the store
# searchable without a wrapper: ripgrep decides how to read a file from it, so
# `.txt.zst` is read as text and a plain `.txt` still left in the store is too.
SUFFIX = '.txt.zst'
PLAIN_SUFFIX = '.txt'
DEFAULT_LEVEL = 3
ZSTD = os.environ.get('FM_ZSTD', 'zstd')


def compressor_path():
    """The zstd binary, or None. Named so the refusal can say what to install."""
    return shutil.which(ZSTD)


def require_compressor():
    if compressor_path():
        return
    print('ERROR: the compressor %r is not on PATH, so this run cannot write the archive.'
          % ZSTD, file=sys.stderr)
    print('       Install zstd (apt install zstd), or point FM_ZSTD at the binary.',
          file=sys.stderr)
    print('       Refusing rather than writing a store that is half compressed and half plain.',
          file=sys.stderr)
    raise SystemExit(4)


def write_session(path, text, level):
    """Write one session file, compressed, atomically.

    Through a temporary file and a rename, because the alternative - a half
    written session that still has a plausible name - is unreadable material
    that looks like readable material.
    """
    tmp = path + '.tmp'
    r = subprocess.run([ZSTD, '-q', '-f', '-%d' % level, '-o', tmp, '-'],
                       input=text.encode('utf-8'))
    if r.returncode != 0:
        try:
            os.remove(tmp)
        except OSError:
            pass
        print('ERROR: %s failed with status %d writing %s'
              % (ZSTD, r.returncode, path), file=sys.stderr)
        raise SystemExit(4)
    os.replace(tmp, path)


def read_session(path):
    """Read one session file back, compressed or plain."""
    if path.endswith('.zst'):
        r = subprocess.run([ZSTD, '-dcq', '--', path], capture_output=True)
        if r.returncode != 0:
            raise OSError('%s could not decompress %s' % (ZSTD, path))
        return r.stdout.decode('utf-8', errors='replace')
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read()


def intact(path):
    """True when zstd can decompress the whole file. A truncated store file is
    not evidence of anything, so it is never the copy that survives."""
    return subprocess.run([ZSTD, '-t', '-q', '--', path],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def converge_store(outdir, level):
    """Leave every session in the store as exactly one compressed file.

    Run after a build, so a store never ends up half one thing and half the
    other: sessions just rewritten drop their superseded plain copy, and
    sessions the raw store no longer has - which a rebuild cannot reach and must
    not remove - are compressed where they lie. Returns (compressed, dropped).
    """
    compressed = dropped = 0
    for root, _, names in os.walk(outdir):
        for n in sorted(names):
            if not n.endswith(PLAIN_SUFFIX):
                continue
            plain = os.path.join(root, n)
            zst = plain + '.zst'
            if os.path.exists(zst) and intact(zst):
                os.remove(plain)
                dropped += 1
                continue
            with open(plain, encoding='utf-8', errors='replace') as fh:
                write_session(zst, fh.read(), level)
            os.remove(plain)
            compressed += 1
    return compressed, dropped


# ---------------------------------------------------------------- shape

# The two record shapes share no key, which is exactly why a wrong --source is
# silent rather than noisy: neither reader raises on the other's material, it
# just matches nothing. Detection therefore keys on the discriminating shape of
# a record, not on a filename or a directory, so a file that wandered into the
# wrong tree is caught by what is in it.
CODEX_RECORD_TYPES = frozenset((
    'response_item', 'event_msg', 'session_meta', 'turn_context',
    'compacted', 'turn_aborted',
))
CLAUDE_RECORD_TYPES = frozenset(('user', 'assistant', 'summary', 'system'))


def detect_shape(path, max_lines=40):
    """Return 'claude', 'codex', or None when the first records decide nothing."""
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if not isinstance(d, dict):
                    continue
                if isinstance(d.get('payload'), dict) or d.get('type') in CODEX_RECORD_TYPES:
                    return 'codex'
                if isinstance(d.get('message'), dict) or d.get('type') in CLAUDE_RECORD_TYPES:
                    return 'claude'
    except OSError:
        return None
    return None


def preflight_shape(files, source, indir, sample=5):
    """Refuse before writing when the input disagrees with --source.

    Returns the number of files whose shape could not be decided; raises SystemExit
    on a genuine mismatch. Naming the paths matters more than naming a count: the
    operator needs to see WHICH tree they pointed at.
    """
    mismatched = []
    undecided = 0
    for f in files:
        shape = detect_shape(f)
        if shape is None:
            undecided += 1
        elif shape != source:
            mismatched.append((f, shape))
    if mismatched:
        other = mismatched[0][1]
        print('ERROR: --source %s, but %d of %d files under %s are %s-shaped.'
              % (source, len(mismatched), len(files), indir, other), file=sys.stderr)
        print('       A %s reader reads %s material as zero entries and reports no error,'
              % (source, other), file=sys.stderr)
        print('       so this run is refused before it writes an empty archive.', file=sys.stderr)
        for f, shape in mismatched[:sample]:
            print('       %s-shaped: %s' % (shape, f), file=sys.stderr)
        if len(mismatched) > sample:
            print('       ... and %d more' % (len(mismatched) - sample), file=sys.stderr)
        raise SystemExit(2)
    return undecided


# ---------------------------------------------------------------- helpers

def load_injected(path):
    """First lines that mark a machine-injected user message. From a file,
    never from a command line, for the same reason patterns.txt is."""
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            line = line.rstrip('\n')
            if line.strip() and not line.lstrip().startswith('#'):
                out.append(line)
    return out


def fold_injected(body, marks, head=200, tail=800):
    """Keep the marker and the tail (where the real instruction sits), drop the
    re-injected middle. Returns (text, folded?)."""
    first = str(body).split('\n', 1)[0]
    if not any(first.startswith(mk) for mk in marks):
        return body, False
    s = str(body)
    if len(s) <= head + tail:
        return body, False
    return ('%s\n    ... [machine-injected block, %d chars folded away]\n%s'
            % (s[:head], len(s) - head - tail, s[-tail:])), True


def trunc(s, n):
    if s is None:
        return ''
    s = str(s)
    if len(s) <= n:
        return s
    return s[:n] + '\n    ... [+%d chars discarded]' % (len(s) - n)


def ts(rec_ts):
    if not rec_ts:
        return '-'
    return str(rec_ts)[:19].replace('T', ' ')


def flatten_content(c):
    """Claude tool_result content -> text."""
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for b in c:
            if isinstance(b, dict):
                parts.append(b.get('text') or b.get('content') or json.dumps(b)[:200])
            else:
                parts.append(str(b))
        return '\n'.join(str(p) for p in parts)
    if c is None:
        return ''
    return json.dumps(c)


# ---------------------------------------------------------------- claude

def reduce_claude(path, N):
    """Yield (kind, timestamp, label, body) tuples."""
    meta = {'cwd': None, 'branch': None, 'version': None, 'first': None, 'last': None}
    out = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get('type')
            if d.get('cwd') and not meta['cwd']:
                meta['cwd'] = d['cwd']
            if d.get('gitBranch') and not meta['branch']:
                meta['branch'] = d['gitBranch']
            if d.get('version') and not meta['version']:
                meta['version'] = d['version']
            tstamp = d.get('timestamp')
            if tstamp:
                meta['first'] = meta['first'] or tstamp
                meta['last'] = tstamp
            if t not in ('user', 'assistant'):
                continue
            m = d.get('message')
            if not isinstance(m, dict):
                continue
            role = m.get('role') or t
            sidechain = ' (subagent)' if d.get('isSidechain') else ''
            c = m.get('content')
            if isinstance(c, str):
                out.append(('msg', tstamp, role + sidechain, c))
                continue
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                bt = b.get('type')
                if bt == 'text':
                    out.append(('msg', tstamp, role + sidechain, b.get('text', '')))
                elif bt == 'thinking':
                    out.append(('think', tstamp, role + sidechain,
                                trunc(b.get('thinking', ''), N)))
                elif bt == 'tool_use':
                    name = b.get('name', '?')
                    inp = b.get('input') or {}
                    out.append(('call', tstamp, name, render_tool_input(name, inp, N)))
                elif bt == 'tool_result':
                    body = flatten_content(b.get('content'))
                    out.append(('out', tstamp, 'tool_result', trunc(body, N)))
    return meta, out


def render_tool_input(name, inp, N):
    """A command is kept verbatim; anything else is truncated but keyed."""
    if not isinstance(inp, dict):
        return trunc(inp, N)
    if 'command' in inp and isinstance(inp['command'], str):
        head = '$ ' + inp['command']
        if inp.get('description'):
            head += '\n  # ' + str(inp['description'])
        return head
    if 'command' in inp and isinstance(inp['command'], list):
        return '$ ' + ' '.join(str(x) for x in inp['command'])
    lines = []
    for k in ('file_path', 'path', 'notebook_path', 'url', 'pattern', 'glob', 'query'):
        if inp.get(k):
            lines.append('%s: %s' % (k, inp[k]))
    rest = {k: v for k, v in inp.items()
            if k not in ('file_path', 'path', 'notebook_path', 'url', 'pattern', 'glob', 'query')}
    if rest:
        lines.append(trunc(json.dumps(rest, ensure_ascii=False), N))
    return '\n'.join(lines) if lines else '(no input)'


# ---------------------------------------------------------------- codex

def reduce_codex(path, N, injected=()):
    meta = {'cwd': None, 'branch': None, 'version': None, 'first': None, 'last': None,
            'model': None}
    out = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            tstamp = d.get('timestamp')
            if tstamp:
                meta['first'] = meta['first'] or tstamp
                meta['last'] = tstamp
            rt = d.get('type')
            p = d.get('payload')
            if not isinstance(p, dict):
                continue
            if rt == 'session_meta':
                meta['cwd'] = meta['cwd'] or p.get('cwd')
                meta['version'] = meta['version'] or p.get('cli_version')
                g = p.get('git') or {}
                if isinstance(g, dict):
                    meta['branch'] = meta['branch'] or g.get('branch')
                continue
            if rt == 'turn_context':
                meta['model'] = meta['model'] or p.get('model')
                meta['cwd'] = meta['cwd'] or p.get('cwd')
                continue
            pt = p.get('type')
            if pt == 'user_message':
                body, folded = fold_injected(p.get('message', ''), injected)
                out.append(('inject' if folded else 'msg', tstamp, 'user', body))
            elif pt == 'agent_message':
                out.append(('msg', tstamp, 'assistant', p.get('message', '')))
            elif pt == 'message':
                role = p.get('role', '?')
                body = flatten_codex_content(p.get('content'))
                if role == 'developer':
                    # standing instructions, re-sent every session; keyed, not kept
                    out.append(('think', tstamp, 'developer', trunc(body, N)))
                else:
                    body, folded = fold_injected(body, injected)
                    out.append(('inject' if folded else 'msg', tstamp, role, body))
            elif pt == 'reasoning':
                s = p.get('summary')
                body = flatten_codex_content(s)
                if body.strip():
                    out.append(('think', tstamp, 'assistant', trunc(body, N)))
                # encrypted_content is an opaque blob: discarded, never scanned
            elif pt in ('function_call', 'custom_tool_call'):
                name = p.get('name', '?')
                raw = p.get('arguments') if pt == 'function_call' else p.get('input')
                out.append(('call', tstamp, name, render_codex_call(name, raw, N)))
            elif pt in ('function_call_output', 'custom_tool_call_output'):
                o = p.get('output')
                if isinstance(o, dict):
                    o = o.get('output') or json.dumps(o, ensure_ascii=False)
                out.append(('out', tstamp, 'tool_result', trunc(o, N)))
            elif pt == 'context_compacted' or rt == 'compacted':
                out.append(('mark', tstamp, 'compaction', '--- context compacted ---'))
    return meta, out


def flatten_codex_content(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for b in c:
            if isinstance(b, dict):
                parts.append(b.get('text') or b.get('summary_text') or '')
            else:
                parts.append(str(b))
        return '\n'.join(p for p in parts if p)
    return '' if c is None else str(c)


def render_codex_call(name, raw, N):
    obj = raw
    if isinstance(raw, str):
        try:
            obj = json.loads(raw)
        except Exception:
            return trunc(raw, N) if name != 'apply_patch' else trunc(raw, N)
    if isinstance(obj, dict):
        if isinstance(obj.get('cmd'), str):
            head = '$ ' + obj['cmd']
        elif isinstance(obj.get('command'), list):
            head = '$ ' + ' '.join(str(x) for x in obj['command'])
        elif isinstance(obj.get('command'), str):
            head = '$ ' + obj['command']
        else:
            return trunc(json.dumps(obj, ensure_ascii=False), N)
        if obj.get('workdir'):
            head += '\n  # in ' + str(obj['workdir'])
        return head
    return trunc(str(obj), N)


# ---------------------------------------------------------------- emit

KIND_TAG = {'msg': '', 'think': ' [reasoning]', 'call': ' [command]',
            'out': ' [result]', 'mark': '', 'inject': ' [injected]'}


def emit(meta, entries, pats, counter, src, rel):
    lines = []
    lines.append('# session %s' % rel)
    lines.append('# source   %s' % src)
    lines.append('# cwd      %s' % (meta.get('cwd') or '-'))
    lines.append('# branch   %s' % (meta.get('branch') or '-'))
    lines.append('# tool     %s' % (meta.get('version') or meta.get('model') or '-'))
    lines.append('# span     %s .. %s' % (ts(meta.get('first')), ts(meta.get('last'))))
    lines.append('# NOTE: reduced derivative. Messages and commands verbatim; tool results')
    lines.append('#       truncated. Redaction is exactly as good as patterns.txt and no')
    lines.append('#       better. What the reduction discarded was never scanned.')
    lines.append('')
    for kind, tstamp, label, body in entries:
        body, _ = redact(body, pats, counter)
        if body is None or not str(body).strip():
            continue
        lines.append('[%s] %s%s' % (ts(tstamp), label, KIND_TAG.get(kind, '')))
        for l in str(body).split('\n'):
            lines.append('    ' + l)
        lines.append('')
    return '\n'.join(lines)


DEFAULT_PATTERNS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                'fm-transcript-patterns', 'patterns.txt')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', choices=('claude', 'codex'),
                    help='required unless --verify-only; selects the reader')
    ap.add_argument('--in', dest='indir',
                    help='required unless --verify-only; the raw session tree')
    ap.add_argument('--out', dest='outdir', required=True)
    ap.add_argument('--patterns', default=DEFAULT_PATTERNS)
    ap.add_argument('--truncate', type=int, default=400)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--level', type=int, default=DEFAULT_LEVEL,
                    help='zstd compression level (default %d); measured on this '
                         'fleet in docs/session-archive.md' % DEFAULT_LEVEL)
    ap.add_argument('--fold-injected', action='store_true',
                    help='codex only: fold machine-injected user messages listed in '
                         'injected-prefixes.txt down to their marker and their tail')
    ap.add_argument('--verify-only', action='store_true',
                    help='rescan an existing derivative and require zero hits')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()

    if not a.verify_only:
        missing = [f for f, v in (('--source', a.source), ('--in', a.indir)) if not v]
        if missing:
            ap.error('%s required unless --verify-only' % ' and '.join(missing))

    pats = load_patterns(a.patterns)
    injected = load_injected(os.path.join(os.path.dirname(os.path.abspath(a.patterns)),
                                          'injected-prefixes.txt')) if a.fold_injected else []

    if a.verify_only:
        total = Counter()
        files = 0
        unreadable = []
        for root, _, names in os.walk(a.outdir):
            for n in sorted(names):
                if not (n.endswith(SUFFIX) or n.endswith(PLAIN_SUFFIX)):
                    continue
                p = os.path.join(root, n)
                # Verification reads the store the way a search reads it, through
                # the decompressor. A file it cannot read is named as unread and
                # never counted as a file that came back clean.
                try:
                    body = read_session(p)
                except OSError as e:
                    unreadable.append('%s: %s' % (p, e))
                    continue
                files += 1
                h = scan(body, pats)
                if h:
                    print('HIT %s %s' % (p, dict(h)))
                total.update(h)
        if unreadable:
            print('ERROR: %d file(s) under %s could not be read, so they were not '
                  'verified:' % (len(unreadable), a.outdir), file=sys.stderr)
            for u in unreadable[:5]:
                print('       %s' % u, file=sys.stderr)
            return 2
        if not files:
            # Zero hits over zero files is not an all-clear, it is a reading the
            # detector could not take. Reporting it as clean is the same silent
            # emptiness a wrong --source produces one step earlier.
            print('ERROR: nothing to verify under %s; no derivative files were found.'
                  % a.outdir, file=sys.stderr)
            return 3
        print('verify: %d files scanned, %d residual hits %s'
              % (files, sum(total.values()), dict(total) or ''))
        return 0 if not total else 2

    if a.source == 'claude':
        files = []
        for root, _, names in os.walk(a.indir):
            for n in names:
                if n.endswith('.jsonl'):
                    files.append(os.path.join(root, n))
    else:
        files = []
        for root, _, names in os.walk(a.indir):
            for n in names:
                if n.startswith('rollout-') and n.endswith('.jsonl'):
                    files.append(os.path.join(root, n))
    require_compressor()

    files.sort()
    if a.limit:
        files = files[:a.limit]

    if not files:
        print('ERROR: no %s-shaped transcripts found under %s; nothing to reduce.'
              % (a.source, a.indir), file=sys.stderr)
        print('       Refusing rather than writing an empty archive that looks built.',
              file=sys.stderr)
        return 3
    undecided = preflight_shape(files, a.source, a.indir)

    os.makedirs(a.outdir, exist_ok=True)
    counter = Counter()
    bytes_in = bytes_out = bytes_disk = 0
    total_entries = 0
    index = []
    t0 = time.time()
    for i, f in enumerate(files, 1):
        rel = os.path.relpath(f, a.indir)
        try:
            bytes_in += os.path.getsize(f)
            if a.source == 'claude':
                meta, entries = reduce_claude(f, a.truncate)
            else:
                meta, entries = reduce_codex(f, a.truncate, injected)
        except Exception as e:
            print('SKIP %s: %s' % (rel, e), file=sys.stderr)
            continue
        total_entries += len(entries)
        text = emit(meta, entries, pats, counter, a.source, rel)
        outrel = rel[:-len('.jsonl')] + SUFFIX
        outp = os.path.join(a.outdir, outrel)
        os.makedirs(os.path.dirname(outp), exist_ok=True)
        write_session(outp, text, a.level)
        bytes_out += len(text.encode('utf-8'))
        bytes_disk += os.path.getsize(outp)
        first_user = ''
        for k, _, lab, b in entries:
            if k == 'msg' and lab.startswith('user') and str(b).strip():
                first_user = redact(str(b).strip(), pats, Counter())[0][:160]
                break
        index.append('\t'.join([
            outrel, ts(meta.get('first')), ts(meta.get('last')),
            meta.get('cwd') or '-', str(len(entries)),
            first_user.replace('\t', ' ').replace('\n', ' ')]))
        if not a.quiet and i % 100 == 0:
            print('  %d/%d  %.0fs' % (i, len(files), time.time() - t0), file=sys.stderr)

    conv, dropped = converge_store(a.outdir, a.level)
    if conv or dropped:
        print('converged       %d retained session(s) compressed, %d superseded plain '
              'copy(ies) dropped' % (conv, dropped))

    with open(os.path.join(a.outdir, '_index.tsv'), 'w', encoding='utf-8') as fh:
        fh.write('# path\tfirst\tlast\tcwd\tentries\tfirst_user_message\n')
        fh.write('\n'.join(sorted(index)) + '\n')

    print('source          %s' % a.source)
    print('files           %d' % len(files))
    print('entries         %d' % total_entries)
    if undecided:
        print('shape undecided %d  (files whose first records identify neither shape)'
              % undecided)
    print('raw bytes       %d  (%.1f MB)' % (bytes_in, bytes_in / 1048576))
    print('derivative      %d  (%.1f MB)  text as searched' % (bytes_out, bytes_out / 1048576))
    print('on disk         %d  (%.1f MB)  zstd -%d' % (bytes_disk, bytes_disk / 1048576, a.level))
    if bytes_out:
        print('reduction       %.1f:1' % (bytes_in / bytes_out))
    if bytes_disk:
        print('compression     %.1f:1  (%.1f:1 against the raw store)'
              % (bytes_out / bytes_disk, bytes_in / bytes_disk))
    print('redactions      %d' % sum(counter.values()))
    for k, v in counter.most_common():
        print('   %-24s %d' % (k, v))
    print('elapsed         %.0fs' % (time.time() - t0))

    # Last net under the pre-flight: a shape neither reader recognises still
    # produces an archive of empty files, and an empty archive that exits 0 is
    # indistinguishable from a quiet fleet. Report it as the failure it is.
    if total_entries == 0:
        print('ERROR: read %d files under %s and recovered zero entries from all of them.'
              % (len(files), a.indir), file=sys.stderr)
        print('       The --source %s reader matched nothing; the archive it just wrote is empty.'
              % a.source, file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
