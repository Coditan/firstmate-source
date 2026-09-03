#!/usr/bin/env python3
"""Generate and check docs/command-domain-map.md.

The map is derived from the current top-level bin/ inventory, each command's
own header, literal references from tracked files, and a small domain vocabulary
kept here beside the command that applies it.
It records evidence for later bin/ reorganization work, but it never proposes or
performs any move.
"""

from __future__ import annotations

import argparse
import dataclasses
import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path


MAP_PATH = Path("docs/command-domain-map.md")
REFERENCE_EXCLUDE_PATHS = {
    MAP_PATH,
    Path("docs/scripts.md"),
    Path("bin/fm-toolbelt-domain-map.py"),
}


@dataclasses.dataclass(frozen=True)
class Domain:
    slug: str
    label: str
    boundary: str
    patterns: tuple[str, ...]
    path_hints: tuple[str, ...] = ()


DOMAINS: tuple[Domain, ...] = (
    Domain(
        "session-bootstrap",
        "Session bootstrap and home currency",
        "Session start, startup diagnostics, self-update, fleet sync, home identity, locks, and startup tangles.",
        (
            r"\bsession[- ]start\b",
            r"\bbootstrap\b",
            r"\bself[- ]update\b",
            r"\bfleet sync\b",
            r"\bfleet[- ]sync\b",
            r"\bvessel identity\b",
            r"\bsession lock\b",
            r"\btangle\b",
            r"\bgate[- ]context\b",
            r"\bprimary checkout\b",
        ),
        ("docs/session", "docs/vessel-identity", "docs/architecture"),
    ),
    Domain(
        "dispatch-backends",
        "Dispatch, harnesses, and terminal backends",
        "Harness detection, backend adapters, dispatch profiles, spawn, send, pane reads, slots, and terminal primitives.",
        (
            r"\bdispatch\b",
            r"\bspawn\b",
            r"\bharness\b",
            r"\bbackend\b",
            r"\btmux\b",
            r"\bzellij\b",
            r"\bcmux\b",
            r"\borca\b",
            r"\bherdr\b",
            r"\bpane\b",
            r"\bslot\b",
            r"\bcomposer\b",
        ),
        ("docs/herdr", "docs/tmux", "docs/zellij", "docs/cmux", "docs/orca", "tests/*backend*"),
    ),
    Domain(
        "supervision-wake",
        "Supervision, wake delivery, and event flow",
        "Watcher loops, wake queue, delivery listener, journal, event batching, turn-end guard, and primary-seat continuity.",
        (
            r"\bwatcher\b",
            r"\bwake\b",
            r"\bdelivery\b",
            r"\bjournal\b",
            r"\bevent batch",
            r"\bturn[- ]end\b",
            r"\bseat respawner\b",
            r"\bstay[- ]down\b",
            r"\bsupervision\b",
            r"\bdaemon watcher\b",
        ),
        ("docs/wake", "docs/event", "docs/turnend", "docs/watcher", "tests/*wake*", "tests/*watch*"),
    ),
    Domain(
        "afk",
        "Away mode",
        "Away-mode launch, return, daemon supervision, and away-specific escalation.",
        (
            r"\baway[- ]mode\b",
            r"\baway daemon\b",
            r"\bafk\b",
            r"\breturn shutdown\b",
            r"\bsub-supervisor\b",
        ),
        ("tests/*afk*", ".agents/skills/afk"),
    ),
    Domain(
        "secondmates-projects",
        "Secondmates, project registry, and local material",
        "Secondmate homes, inherited local material, project delivery modes, project removal, and secondmate handoff/reporting.",
        (
            r"\bsecondmate\b",
            r"\bsecondmates\b",
            r"\bproject clone\b",
            r"\bproject delivery\b",
            r"\bdelivery mode\b",
            r"\binherited local material\b",
            r"\bproject mode\b",
            r"\bproject remove\b",
            r"\bhome seed\b",
        ),
        ("docs/configuration", "tests/*secondmate*", ".agents/skills/secondmate"),
    ),
    Domain(
        "task-lifecycle",
        "Task lifecycle and status records",
        "Task briefs, promotion from scout to ship, parking, current-state reads, and backend-neutral transition records.",
        (
            r"\btask brief\b",
            r"\bbriefs\b",
            r"\bpromote\b",
            r"\bscout task\b",
            r"\bship task\b",
            r"\bparked\b",
            r"\bcurrent-state\b",
            r"\btransition record\b",
            r"\bstatus line\b",
        ),
        ("tests/fm-brief", "tests/fm-promote", "tests/fm-crew-state", "tests/fm-transition"),
    ),
    Domain(
        "decisions-backlog",
        "Decisions, backlog, boards, and planning surfaces",
        "Captain decision records, backlog decomposition and linting, boards, sea charts, and related presentation surfaces.",
        (
            r"\bdecision\b",
            r"\bbacklog\b",
            r"\bblocked-by\b",
            r"\bboard\b",
            r"\bsea chart\b",
            r"\bchart\b",
            r"\bto-backlog\b",
            r"\bplanning\b",
            r"\bfog\b",
        ),
        ("docs/board", "docs/sea-chart", ".agents/skills/decision", ".agents/skills/to-backlog"),
    ),
    Domain(
        "findings-urgency",
        "Findings and urgency",
        "Findings-surface records, finding drain, urgency classification, and promotion of understated events.",
        (
            r"\bfinding\b",
            r"\bfindings\b",
            r"\burgency\b",
            r"\bpromot",
            r"\bseverity\b",
            r"\bdeadline\b",
        ),
        ("docs/findings", "docs/urgency", "tests/*finding*", "tests/*urgency*"),
    ),
    Domain(
        "pr-forge-landing",
        "PR, forge, landing, and teardown",
        "Pull request checks, merge/landing helpers, teardown, review diffs, deploy verification, and forge-specific handoffs.",
        (
            r"\bpull request\b",
            r"\bpr\b",
            r"\bmerge\b",
            r"\bteardown\b",
            r"\bforge\b",
            r"\bgithub\b",
            r"\bdeploy\b",
            r"\blanding\b",
            r"\bchecks green\b",
            r"\bbranch deletion\b",
        ),
        ("docs/merge", "docs/github", "docs/forge", "tests/*pr-*", "tests/*teardown*"),
    ),
    Domain(
        "messaging-bridge",
        "Messaging, Bridge, Telegram, and X mode",
        "Bridge relay and inbox traffic, frequency monitor, direct Telegram send/receive, and X-mode mentions/replies.",
        (
            r"\bbridge\b",
            r"\btelegram\b",
            r"\btg[- ]",
            r"\binbox\b",
            r"\bmessage\b",
            r"\bmentions\b",
            r"\bx-mode\b",
            r"\btweet\b",
            r"\breply threading\b",
            r"\bfrequency monitor\b",
        ),
        ("docs/telegram", "docs/github-inbox", ".agents/skills/fmx", "tests/*x-mode*"),
    ),
    Domain(
        "external-currency",
        "External watches and currency checks",
        "Checks that compare this home, its tools, or external services against upstream state on a cadence or on demand.",
        (
            r"\bcurrency\b",
            r"\bupdate check\b",
            r"\bupstream\b",
            r"\bpin\b",
            r"\bforge status\b",
            r"\bdaily\b",
            r"\bcadence\b",
            r"\bovertaken\b",
            r"\bsource comparison\b",
        ),
        ("docs/currency", "docs/pin-age", "docs/forge-status", "tests/*currency*"),
    ),
    Domain(
        "memory-context",
        "Memory, context ceiling, and transcript archive",
        "Memory readings and alarms, context-ceiling reset mechanics, stow receipts, and transcript archive/search tooling.",
        (
            r"\bmemory\b",
            r"\bcontext[- ]ceiling\b",
            r"\bcontext reset\b",
            r"\bstow\b",
            r"\btranscript\b",
            r"\bsession archive\b",
            r"\barchive\b",
            r"\bcompressed store\b",
        ),
        ("docs/memory", "docs/context-reset", "docs/session-archive", ".agents/skills/stow"),
    ),
    Domain(
        "knowledge-review",
        "Knowledge, review quality, and generated artifacts",
        "Research/review quality measurement, model panels, PDF production, Lavish boards, AGENTS.md maintenance, and generated command maps.",
        (
            r"\breview quality\b",
            r"\bmodel panel\b",
            r"\bpanel\b",
            r"\bpdf\b",
            r"\blavish\b",
            r"\bagents\.md\b",
            r"\bcommand domain map\b",
            r"\btoolbelt domain map\b",
            r"\bgenerated map\b",
            r"\bgrade\b",
        ),
        ("docs/review", "docs/pdf", "docs/lavish", ".agents/skills/panel"),
    ),
    Domain(
        "service-access",
        "Local service access",
        "Vessel-local service address resolution, reachable-link publication, and bind-proven port selection.",
        (
            r"\bvessel-local service\b",
            r"\breachable address\b",
            r"\bport\b",
            r"\bbind\b",
            r"\breachability\b",
            r"\btailnet\b",
            r"\bloopback\b",
            r"\bservice-port\b",
        ),
        ("docs/fleet-service-port-registry", "tests/fm-lavish-access", "tests/fm-board"),
    ),
    Domain(
        "policy-hooks",
        "Command policy hooks",
        "PreToolUse transports and semantic command-policy parsers for arm, cd, continuity, Lavish, and subagent guards.",
        (
            r"\bpretooluse\b",
            r"\bcommand policy\b",
            r"\bpolicy parser\b",
            r"\bcd-guard\b",
            r"\bcontinuity gate\b",
            r"\bsubagent guard\b",
            r"\bprotected command\b",
            r"\bhook\b",
        ),
        ("docs/arm-pretool-check", "docs/cd-guard", "docs/subagent-guard", ".codex", ".claude"),
    ),
    Domain(
        "tests-tooling",
        "Tests, lint, and tool installation",
        "Test runner, isolation proof, shell lint, pinned tool installers, AXI suite checks, and validation-daemon integration.",
        (
            r"\btest runner\b",
            r"\bbehavior-test\b",
            r"\bcoverage guard\b",
            r"\bshellcheck\b",
            r"\blint\b",
            r"\binstall\b",
            r"\baxi suite\b",
            r"\bvalidation daemon\b",
            r"\bno-mistakes\b",
            r"\bci\b",
        ),
        (".github/workflows", "tests/fm-lint", "tests/fm-test", "docs/fm-test"),
    ),
    Domain(
        "fleet-snapshot",
        "Fleet snapshot and bearings",
        "Read-only fleet snapshots, human fleet views, bearings projections, and blocker projection helpers.",
        (
            r"\bfleet snapshot\b",
            r"\bsnapshot\b",
            r"\bbearings\b",
            r"\bfleet view\b",
            r"\bprojection\b",
            r"\bread-only structured fleet\b",
        ),
        (".agents/skills/bearings", "docs/board-appearance", "tests/*fleet-snapshot*", "tests/*bearings*"),
    ),
    Domain(
        "bosun-service",
        "Bosun observer",
        "Observer-only bosun judging, records, health, and service convergence.",
        (
            r"\bbosun\b",
            r"\bobserver\b",
            r"\bjudge\b",
            r"\bjudgement\b",
            r"\bverdict record\b",
        ),
        ("docs/bosun", "tests/*bosun*"),
    ),
)


NAME_HINTS: tuple[tuple[str, str, int], ...] = (
    ("fm-afk*", "afk", 5),
    ("fm-supervise-daemon.sh", "afk", 6),
    ("fm-backend*", "dispatch-backends", 4),
    ("fm-harness*", "dispatch-backends", 4),
    ("fm-spawn.sh", "dispatch-backends", 5),
    ("fm-send.sh", "dispatch-backends", 4),
    ("fm-tmux*", "dispatch-backends", 4),
    ("fm-slot*", "dispatch-backends", 3),
    ("fm-composer*", "dispatch-backends", 3),
    ("fm-secondmate*", "secondmates-projects", 5),
    ("fm-home-seed.sh", "secondmates-projects", 5),
    ("fm-config-*", "secondmates-projects", 4),
    ("fm-project-*", "secondmates-projects", 4),
    ("fm-backlog-handoff.sh", "secondmates-projects", 4),
    ("fm-brief.sh", "task-lifecycle", 5),
    ("fm-promote.sh", "task-lifecycle", 6),
    ("fm-mark-parked.sh", "task-lifecycle", 5),
    ("fm-crew-state.sh", "task-lifecycle", 5),
    ("fm-transition-lib.sh", "task-lifecycle", 5),
    ("fm-decision*", "decisions-backlog", 5),
    ("fm-backlog-lint.sh", "decisions-backlog", 4),
    ("fm-board.sh", "decisions-backlog", 4),
    ("fm-sea-chart.sh", "decisions-backlog", 5),
    ("fm-to-backlog.sh", "decisions-backlog", 5),
    ("fm-chart-kinds-lib.sh", "decisions-backlog", 4),
    ("fm-finding*", "findings-urgency", 5),
    ("fm-urgency*", "findings-urgency", 5),
    ("fm-pr-*", "pr-forge-landing", 5),
    ("fm-merge-local.sh", "pr-forge-landing", 5),
    ("fm-teardown.sh", "pr-forge-landing", 5),
    ("fm-review-diff.sh", "pr-forge-landing", 4),
    ("fm-deploy-verify.sh", "pr-forge-landing", 4),
    ("fm-bridge*", "messaging-bridge", 5),
    ("fm-tg-*", "messaging-bridge", 5),
    ("fm-frequency-monitor*", "messaging-bridge", 5),
    ("fm-github-inbox.sh", "messaging-bridge", 4),
    ("fm-x-*", "messaging-bridge", 4),
    ("fm-currency*", "external-currency", 5),
    ("fm-firstmate-update-check.sh", "external-currency", 5),
    ("fm-fleet-update-check.sh", "external-currency", 5),
    ("fm-upstream-distance.sh", "external-currency", 5),
    ("fm-forge-status.sh", "external-currency", 4),
    ("fm-grossreinschiff-due.sh", "external-currency", 3),
    ("fm-memory*", "memory-context", 5),
    ("fm-context*", "memory-context", 4),
    ("fm-stow-receipt.sh", "memory-context", 4),
    ("fm-transcript*", "memory-context", 5),
    ("fm-lavish*", "knowledge-review", 3),
    ("fm-model-panel.sh", "knowledge-review", 5),
    ("fm-grade*", "knowledge-review", 5),
    ("fm-pdf*", "knowledge-review", 5),
    ("fm-ensure-agents-md.sh", "knowledge-review", 5),
    ("fm-toolbelt-domain-map.py", "knowledge-review", 6),
    ("fm-service-port.sh", "service-access", 6),
    ("fm-service-port-probe.mjs", "service-access", 6),
    ("fm-*-pretool-check.sh", "policy-hooks", 5),
    ("fm-*-command-policy.mjs", "policy-hooks", 5),
    ("fm-subagent-pretool-check.sh", "policy-hooks", 5),
    ("fm-lint.sh", "tests-tooling", 5),
    ("fm-test-*.sh", "tests-tooling", 5),
    ("fm-install-*.sh", "tests-tooling", 4),
    ("fm-axi-suite.sh", "tests-tooling", 4),
    ("fm-nm-path-lib.sh", "tests-tooling", 3),
    ("fm-fleet-snapshot.sh", "fleet-snapshot", 5),
    ("fm-fleet-view.sh", "fleet-snapshot", 5),
    ("fm-bearings-snapshot.sh", "fleet-snapshot", 5),
    ("fm-blocker-class-lib.sh", "fleet-snapshot", 3),
    ("fm-bosun*", "bosun-service", 6),
    ("fm-session-start.sh", "session-bootstrap", 6),
    ("fm-sessionstart-nudge.sh", "session-bootstrap", 5),
    ("fm-bootstrap.sh", "session-bootstrap", 5),
    ("fm-fleet-sync.sh", "session-bootstrap", 5),
    ("fm-absence-lib.sh", "session-bootstrap", 3),
    ("fm-update.sh", "session-bootstrap", 5),
    ("fm-vessel-identity.sh", "session-bootstrap", 5),
    ("fm-primary-scope-lib.sh", "policy-hooks", 5),
    ("fm-role-lib.sh", "session-bootstrap", 5),
    ("fm-lock*", "session-bootstrap", 4),
    ("fm-tangle*", "session-bootstrap", 4),
    ("fm-gate-refuse*", "session-bootstrap", 4),
    ("fm-watch*", "supervision-wake", 5),
    ("fm-wake*", "supervision-wake", 5),
    ("fm-delivery*", "supervision-wake", 5),
    ("fm-seat-stay-down.sh", "supervision-wake", 6),
    ("fm-journal*", "supervision-wake", 5),
    ("fm-event-batch*", "supervision-wake", 5),
    ("fm-turnend-guard*", "supervision-wake", 4),
    ("fm-supervision*", "supervision-wake", 4),
    ("fm-supervise-daemon.sh", "supervision-wake", 4),
    ("fm-crew-state.sh", "supervision-wake", 3),
    ("fm-check-*", "supervision-wake", 3),
    ("fm-mark-parked.sh", "supervision-wake", 3),
    ("fm-keeper-name-lib.sh", "supervision-wake", 3),
    ("fm-pane-activity-lib.sh", "supervision-wake", 3),
    ("fm-bounded-lib.sh", "supervision-wake", 3),
    ("fm-state-marker-prune-lib.sh", "supervision-wake", 3),
)


def run_git_ls(root: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise SystemExit(f"fm-toolbelt-domain-map: cannot list tracked files: {exc}") from exc
    return [root / line for line in result.stdout.splitlines() if line]


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="replace")


def top_level_commands(root: Path) -> list[Path]:
    return sorted((root / "bin").iterdir(), key=lambda p: p.name)


def comment_text(line: str) -> str | None:
    stripped = line.strip()
    if stripped.startswith("#!"):
        return ""
    if stripped.startswith("#"):
        return stripped[1:].strip()
    if stripped.startswith("//"):
        return stripped[2:].strip()
    return None


def header_lines(path: Path) -> list[str]:
    lines = read_text(path).splitlines()
    header: list[str] = []
    if path.suffix == ".py":
        doc = re.search(r'"""(.*?)"""', "\n".join(lines[:80]), re.S)
        if doc:
            return [line.strip() for line in doc.group(1).splitlines() if line.strip()]
    for line in lines[:80]:
        if not line.strip():
            if header:
                break
            continue
        text = comment_text(line)
        if text is None:
            break
        if text.startswith("shellcheck "):
            continue
        if text:
            header.append(text)
    return header


def purpose_for(path: Path) -> str:
    base = path.name
    header = header_lines(path)
    for index, line in enumerate(header):
        match = re.match(rf"(?:bin/)?{re.escape(base)}\s+[-:]\s+(.+)$", line)
        if match:
            return one_line(header_sentence([match.group(1), *header[index + 1 :]]))
    for index, line in enumerate(header):
        if line and not line.lower().startswith(("usage:", "why ", "safety", "mechanics")):
            return one_line(header_sentence(header[index:]))
    return "No one-line header purpose found."


def header_sentence(lines: list[str]) -> str:
    parts: list[str] = []
    for line in lines:
        if not line:
            break
        if line.lower().startswith(("usage:", "why ", "safety", "mechanics")):
            break
        parts.append(line)
        if line.endswith((".", "!", "?")):
            break
    return " ".join(parts)


def one_line(value: str) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    return value.rstrip(".")


def source_kind(path: Path, text: str) -> str:
    rel = path.as_posix()
    if rel.startswith("tests/"):
        return "tests"
    if rel.startswith("bin/"):
        if path.name.endswith(("-service.sh", "-keeper.sh")):
            return "scripts/systemd"
        return "scripts"
    if rel.startswith(".agents/skills/"):
        return "skills"
    if rel.startswith("docs/"):
        return "documentation"
    if rel.startswith(".github/workflows/"):
        return "workflows"
    if rel.startswith(".codex/") or rel.startswith(".claude/") or rel.startswith(".pi/"):
        return "hooks"
    if rel.endswith(".service") or "systemd" in text.lower():
        return "systemd"
    return "tracked"


def references_for(root: Path, command: Path, tracked_texts: dict[Path, str]) -> dict[str, list[str]]:
    refs: dict[str, list[str]] = {}
    needle = command.name
    for path, text in tracked_texts.items():
        rel = path.relative_to(root)
        if rel in REFERENCE_EXCLUDE_PATHS:
            continue
        if path == command or not path.is_file():
            continue
        if needle not in text:
            continue
        kind = source_kind(rel, text)
        refs.setdefault(kind, []).append(rel.as_posix())
    return {kind: sorted(set(paths)) for kind, paths in sorted(refs.items())}


def score_domains(command: Path, purpose: str, refs: dict[str, list[str]]) -> tuple[dict[str, int], dict[str, list[str]]]:
    body = read_text(command)
    ref_text = " ".join(path for paths in refs.values() for path in paths)
    evidence = f"{command.name}\n{purpose}\n{body}\n{ref_text}".lower()
    scores = {domain.slug: 0 for domain in DOMAINS}
    signals = {domain.slug: [] for domain in DOMAINS}
    for pattern, slug, weight in NAME_HINTS:
        if fnmatch.fnmatch(command.name, pattern):
            scores[slug] += weight * 2
            signals[slug].append(f"name:{pattern}")
    for domain in DOMAINS:
        for pattern in domain.patterns:
            if re.search(pattern, evidence, re.I):
                scores[domain.slug] += 1
                signals[domain.slug].append(f"text:{pattern}")
        for hint in domain.path_hints:
            if fnmatch.fnmatch(ref_text, f"*{hint}*"):
                scores[domain.slug] += 1
                signals[domain.slug].append(f"ref:{hint}")
    return scores, signals


def classify(command: Path, purpose: str, refs: dict[str, list[str]]) -> tuple[str, list[str], list[str]]:
    scores, signals = score_domains(command, purpose, refs)
    ranked = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
    if not ranked or ranked[0][1] < 3:
        return "unplaced", [], []
    primary = ranked[0][0]
    secondary = [
        slug
        for slug, score in ranked[1:]
        if score >= 8 and ranked[0][1] - score <= 4
    ]
    primary_signals = signals[primary][:5]
    return primary, secondary[:3], primary_signals


def format_refs(refs: dict[str, list[str]]) -> str:
    if not refs:
        return "No tracked caller or reference found."
    parts: list[str] = []
    for kind, paths in refs.items():
        parts.append(f"{kind}: {', '.join(paths)}")
    return "; ".join(parts)


def md_escape(value: str) -> str:
    return value.replace("|", "\\|")


def generate(root: Path) -> tuple[str, dict[str, int]]:
    commands = [p for p in top_level_commands(root) if p.is_file()]
    tracked = run_git_ls(root)
    tracked_texts = {path: read_text(path) for path in tracked if path.is_file()}
    rows = []
    domains_used: set[str] = set()
    ambiguous = []
    unplaced = []
    unreferenced = []
    for command in commands:
        purpose = purpose_for(command)
        refs = references_for(root, command, tracked_texts)
        domain, secondary, signals = classify(command, purpose, refs)
        if domain == "unplaced":
            unplaced.append(command.name)
        else:
            domains_used.add(domain)
        if secondary:
            ambiguous.append((command.name, domain, secondary))
        if not refs:
            unreferenced.append(command.name)
        rows.append(
            {
                "command": command.name,
                "domain": domain,
                "secondary": secondary,
                "purpose": purpose,
                "signals": signals,
                "refs": refs,
            }
        )
    rows.sort(key=lambda row: (row["domain"], row["command"]))
    ambiguous.sort()
    unplaced.sort()
    unreferenced.sort()

    domain_by_slug = {domain.slug: domain for domain in DOMAINS}
    out: list[str] = []
    out.append("# Firstmate command domain map")
    out.append("")
    out.append("Generated by `bin/fm-toolbelt-domain-map.py --write`.")
    out.append("Do not edit by hand.")
    out.append("It is an evidence map for reviewing a possible later `bin/` reorganization, not permission to move files or a proposed target layout.")
    out.append("")
    out.append("## Summary")
    out.append("")
    out.append(f"- Command count: {len(commands)} top-level files in `bin/`.")
    out.append(f"- Domain count: {len(domains_used)} domains currently used.")
    out.append(f"- Ambiguous command count: {len(ambiguous)}.")
    out.append(f"- Unplaced command count: {len(unplaced)}.")
    out.append(f"- Commands with no tracked caller or reference: {len(unreferenced)}.")
    out.append("")
    out.append("## Domains")
    out.append("")
    for domain in DOMAINS:
        used = sum(1 for row in rows if row["domain"] == domain.slug)
        if used == 0:
            continue
        out.append(f"- `{domain.slug}`: {domain.boundary} ({used} commands.)")
    out.append("")
    out.append("## Ambiguous Commands")
    out.append("")
    if ambiguous:
        out.append("| Command | Primary domain | Also fits |")
        out.append("| --- | --- | --- |")
        for command, primary, secondary in ambiguous:
            out.append(
                f"| `{command}` | `{primary}` | {', '.join(f'`{slug}`' for slug in secondary)} |"
            )
    else:
        out.append("No command currently carries a second strong domain signal.")
    out.append("")
    out.append("## Unplaced Commands")
    out.append("")
    if unplaced:
        for name in unplaced:
            out.append(f"- `{name}`")
    else:
        out.append("No command is unplaced.")
    out.append("")
    out.append("## Commands With No Tracked Caller Or Reference")
    out.append("")
    if unreferenced:
        for name in unreferenced:
            out.append(f"- `{name}`")
    else:
        out.append("Every command has at least one tracked caller or reference.")
    out.append("")
    for domain in DOMAINS:
        domain_rows = [row for row in rows if row["domain"] == domain.slug]
        if not domain_rows:
            continue
        out.append(f"## {domain.label}")
        out.append("")
        out.append("| Command | Purpose from header | Domain evidence | Callers and references |")
        out.append("| --- | --- | --- | --- |")
        for row in domain_rows:
            evidence = ", ".join(row["signals"]) if row["signals"] else "No concise signal recorded."
            refs = format_refs(row["refs"])
            out.append(
                "| "
                f"`{row['command']}` | "
                f"{md_escape(row['purpose'])} | "
                f"{md_escape(evidence)} | "
                f"{md_escape(refs)} |"
            )
        out.append("")
    if unplaced:
        out.append("## Unplaced")
        out.append("")
        out.append("| Command | Purpose from header | Callers and references |")
        out.append("| --- | --- | --- |")
        for row in rows:
            if row["domain"] != "unplaced":
                continue
            out.append(
                "| "
                f"`{row['command']}` | "
                f"{md_escape(row['purpose'])} | "
                f"{md_escape(format_refs(row['refs']))} |"
            )
        out.append("")
    text = "\n".join(out) + "\n"
    stats = {
        "commands": len(commands),
        "domains": len(domains_used),
        "ambiguous": len(ambiguous),
        "unplaced": len(unplaced),
        "unreferenced": len(unreferenced),
    }
    return text, stats


def check(root: Path) -> int:
    wanted, stats = generate(root)
    actual_path = root / MAP_PATH
    if not actual_path.exists():
        print(f"fm-toolbelt-domain-map: missing {MAP_PATH}", file=sys.stderr)
        return 1
    actual = read_text(actual_path)
    if actual != wanted:
        print(f"fm-toolbelt-domain-map: {MAP_PATH} is out of date; run bin/fm-toolbelt-domain-map.py --write", file=sys.stderr)
        print(
            "fm-toolbelt-domain-map: "
            f"commands={stats['commands']} domains={stats['domains']} "
            f"ambiguous={stats['ambiguous']} unplaced={stats['unplaced']}",
            file=sys.stderr,
        )
        return 1
    if stats["unplaced"]:
        print(f"fm-toolbelt-domain-map: {stats['unplaced']} command(s) are unplaced", file=sys.stderr)
        return 1
    print(
        "FM_TOOLBELT_DOMAIN_MAP ok "
        f"commands={stats['commands']} domains={stats['domains']} "
        f"ambiguous={stats['ambiguous']} unplaced={stats['unplaced']}"
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate or check firstmate's command domain map.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help=f"write {MAP_PATH}")
    mode.add_argument("--check", action="store_true", help=f"fail if {MAP_PATH} is stale or has unplaced commands")
    mode.add_argument("--stdout", action="store_true", help="print the generated map")
    parser.add_argument("--root", default=os.environ.get("FM_TOOLBELT_MAP_ROOT", "."), help="repository root to inspect")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(args.root).resolve()
    if args.check:
        return check(root)
    text, stats = generate(root)
    if args.write:
        target = root / MAP_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        print(
            f"wrote {MAP_PATH} commands={stats['commands']} domains={stats['domains']} "
            f"ambiguous={stats['ambiguous']} unplaced={stats['unplaced']}"
        )
        return 0
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
