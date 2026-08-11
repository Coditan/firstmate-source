#!/usr/bin/env python3
"""Measurement engine for what supervision costs a firstmate session.

WHY THIS EXISTS
---------------
Every earlier figure for supervision spend was an estimate: a share of turns
guessed from a transcript, a token count inferred from a byte count, a saving
projected from a change nobody had measured on either side of.  A number in the
wrong unit is worse than no number, because it reads as authoritative and gets
re-quoted.  This reads the provider's own usage records instead, so every figure
below is counted rather than derived.

THE UNIT
--------
FRESH tokens: ``input_tokens + cache_creation_input_tokens`` for one request.
That is what a request newly writes into the provider's window.  Cache READS are
reported separately and never added in: they are carried context, they are
charged at a different rate, and mixing the two produces a number that describes
nothing.  A request's freshly written tokens are the only part a change to
firstmate's own machinery can move, which is exactly why it is the unit here.

Requests are deduplicated by ``requestId``, so a retried request is counted once.

WHAT IS COUNTED
---------------
Sessions       one transcript file, keyed by its session id.  The count per day
               is the restart rate: how often a session had to start over.
Session start  the fresh tokens of a session's FIRST request (system prompt,
               instruction surface, tool schemas - paid before any work), and
               the startup block, which extends that through the first request
               that reads the session-start digest.  A session that never runs
               the digest has no startup block beyond its first request, and is
               reported that way rather than having the whole session counted as
               startup.
Deliveries     one ``<task-notification>`` message: the harness handing a
               completed background task back to the model.  Under a
               background-notify harness that IS the wake.
Segment        every request from one delivery up to the next.  Requests per
               delivery and fresh tokens per delivery are measured over these.
Empty delivery a segment that ran the wake drain and got no queue record back:
               the model was woken, paid for the wake, and there was nothing in
               it.  This is the signature of the re-entry defect.

WHAT IS NOT COUNTED
-------------------
Only Claude Code transcripts are read; other harnesses keep no equivalent local
usage record, so their supervision spend is not measured here at all.  Retention
is the provider's, not this tool's: a day whose transcripts have rolled off is
absent rather than zero, and no figure here is a full-day ledger.  Cost in
currency is deliberately not computed - that needs a price list this tool has no
business pinning, and a subscription window is not the same accounting as an API
bill.
"""

import argparse
import json
import os
import re
import statistics
import sys
from collections import defaultdict

# A drained queue record: epoch, sequence, kind, key, payload.
QUEUE_ROW = re.compile(r"^\d{9,11}\t\d+\t(signal|stale|check|heartbeat)\t")
DRAIN_CALL = "fm-wake-drain.sh"
SESSION_START_CALL = "fm-session-start.sh"
# The digest is meant to be the session's first action, so a session that has
# not read it within this many requests was not starting up - it was working.
# Without this bound one such session turns a whole day's work into a startup
# figure, and a startup figure that includes work is not a startup figure.
STARTUP_REQUEST_LIMIT = 12


def iter_transcripts(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".jsonl"):
                yield os.path.join(dirpath, name)


def read_records(path):
    try:
        handle = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue


def tool_result_text(block):
    content = block.get("content")
    if isinstance(content, list):
        return " ".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    return content or ""


def fresh_tokens(usage):
    return int(usage.get("input_tokens") or 0) + int(
        usage.get("cache_creation_input_tokens") or 0
    )


class SessionMeasurement:
    """One transcript, measured. Segments are delimited by deliveries."""

    def __init__(self, session_id, project):
        self.session_id = session_id
        self.project = project
        self.day = None
        self.requests = 0
        self.fresh = 0
        self.cache_read = 0
        self.output = 0
        self.first_request_fresh = None
        self.startup_fresh = 0
        self.deliveries = 0
        self.segment_requests = []
        self.segment_fresh = []
        self.drain_calls = 0
        self.drain_calls_empty = 0
        self.empty_deliveries = 0
        # An empty delivery is a wake that carried nothing. Its requests and its
        # freshly written tokens are the measured price of the defect, kept apart
        # from the wakes that did carry something so a repair can be judged
        # against a number rather than against a feeling.
        self.empty_delivery_requests = 0
        self.empty_delivery_fresh = 0


def measure_file(path, since, until, seen_requests):
    records = list(read_records(path))
    if not records:
        return None
    records.sort(key=lambda record: record.get("timestamp") or "")

    session_id = os.path.splitext(os.path.basename(path))[0]
    project = os.path.basename(os.path.dirname(path))
    measurement = SessionMeasurement(session_id, project)

    session_day = None
    for record in records:
        if record.get("type") != "assistant":
            continue
        message = record.get("message") or {}
        if not (message.get("usage") or {}) or not record.get("requestId"):
            continue
        timestamp = record.get("timestamp") or ""
        session_day = timestamp[:10] or None
        break
    if session_day is None:
        return None
    if since and session_day < since:
        return None
    if until and session_day > until:
        return None
    measurement.day = session_day

    # Tool-use id -> True for calls that ran the wake drain, so their results can
    # be classified when they come back a message later.
    drain_calls = {}
    session_start_calls = {}
    # The startup block stays open only until the digest has actually been read.
    # A session that never runs it must not have its whole run counted as
    # start-up cost: an open-ended accumulator silently turns one session's real
    # work into a startup figure, which is precisely the kind of number that
    # looks measured and is not.
    startup_open = True
    startup_digest_seen = False
    startup_requests = 0
    segment = None
    segment_drains = 0
    segment_rows = 0

    def close_segment():
        nonlocal segment, segment_drains, segment_rows
        if segment is not None:
            measurement.segment_requests.append(segment[0])
            measurement.segment_fresh.append(segment[1])
            if segment_drains > 0 and segment_rows == 0:
                measurement.empty_deliveries += 1
                measurement.empty_delivery_requests += segment[0]
                measurement.empty_delivery_fresh += segment[1]
        segment = None
        segment_drains = 0
        segment_rows = 0

    for record in records:
        timestamp = record.get("timestamp") or ""
        if not timestamp[:10]:
            continue

        kind = record.get("type")
        if kind == "assistant":
            message = record.get("message") or {}
            usage = message.get("usage") or {}
            request_id = record.get("requestId")
            if usage and request_id and request_id not in seen_requests:
                seen_requests.add(request_id)
                this_fresh = fresh_tokens(usage)
                measurement.requests += 1
                measurement.fresh += this_fresh
                measurement.cache_read += int(usage.get("cache_read_input_tokens") or 0)
                measurement.output += int(usage.get("output_tokens") or 0)
                if measurement.first_request_fresh is None:
                    measurement.first_request_fresh = this_fresh
                if startup_open:
                    measurement.startup_fresh += this_fresh
                    startup_requests += 1
                    if startup_digest_seen or startup_requests >= STARTUP_REQUEST_LIMIT:
                        startup_open = False
                if segment is not None:
                    segment[0] += 1
                    segment[1] += this_fresh
            for block in message.get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                command = (block.get("input") or {}).get("command") or ""
                if DRAIN_CALL in command:
                    drain_calls[block.get("id")] = True
                    measurement.drain_calls += 1
                    segment_drains += 1
                if SESSION_START_CALL in command:
                    session_start_calls[block.get("id")] = True
        elif kind == "user":
            content = (record.get("message") or {}).get("content")
            if isinstance(content, str):
                if "<task-notification>" in content:
                    close_segment()
                    measurement.deliveries += 1
                    segment = [0, 0]
                continue
            for block in content or []:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                text = tool_result_text(block)
                if block.get("tool_use_id") in drain_calls:
                    rows = sum(
                        1 for line in text.split("\n") if QUEUE_ROW.match(line)
                    )
                    if rows == 0:
                        measurement.drain_calls_empty += 1
                    segment_rows += rows
                if block.get("tool_use_id") in session_start_calls:
                    startup_digest_seen = True

    close_segment()
    if measurement.requests == 0:
        return None
    if not startup_digest_seen:
        measurement.startup_fresh = measurement.first_request_fresh or 0
    return measurement


def summarize(values):
    if not values:
        return {"count": 0, "median": 0, "mean": 0.0, "max": 0, "total": 0}
    return {
        "count": len(values),
        "median": statistics.median(values),
        "mean": round(statistics.mean(values), 2),
        "max": max(values),
        "total": sum(values),
    }


def measure(root, since, until, project_filter):
    seen_requests = set()
    sessions = []
    for path in iter_transcripts(root):
        if project_filter and project_filter not in os.path.dirname(path):
            continue
        measurement = measure_file(path, since, until, seen_requests)
        if measurement is not None:
            sessions.append(measurement)

    by_day = defaultdict(list)
    for measurement in sessions:
        by_day[measurement.day].append(measurement)

    days = []
    for day in sorted(by_day):
        group = by_day[day]
        segment_requests = [n for m in group for n in m.segment_requests]
        segment_fresh = [n for m in group for n in m.segment_fresh]
        days.append(
            {
                "day": day,
                "session_starts": len(group),
                "requests": sum(m.requests for m in group),
                "fresh_tokens": sum(m.fresh for m in group),
                "cache_read_tokens": sum(m.cache_read for m in group),
                "output_tokens": sum(m.output for m in group),
                "session_start_fresh": summarize(
                    [
                        m.first_request_fresh
                        for m in group
                        if m.first_request_fresh is not None
                    ]
                ),
                "startup_block_fresh": summarize([m.startup_fresh for m in group]),
                "deliveries": sum(m.deliveries for m in group),
                "requests_per_delivery": summarize(segment_requests),
                "fresh_per_delivery": summarize(segment_fresh),
                "drain_calls": sum(m.drain_calls for m in group),
                "drain_calls_empty": sum(m.drain_calls_empty for m in group),
                "empty_deliveries": sum(m.empty_deliveries for m in group),
                "empty_delivery_requests": sum(
                    m.empty_delivery_requests for m in group
                ),
                "empty_delivery_fresh": sum(m.empty_delivery_fresh for m in group),
            }
        )

    return {
        "unit": "fresh tokens = input_tokens + cache_creation_input_tokens, per unique requestId",
        "not_counted": [
            "harnesses other than Claude Code, which keep no equivalent local usage record",
            "days whose transcripts the provider has already rolled off",
            "currency cost, which needs a price list this tool does not pin",
        ],
        "transcripts_root": root,
        "sessions": len(sessions),
        "days": days,
    }


def print_report(report):
    print(f"unit: {report['unit']}")
    print(f"transcripts: {report['transcripts_root']}")
    print(f"sessions measured: {report['sessions']}")
    print("")
    header = (
        f"{'day':<12}{'starts':>7}{'start-fresh':>13}{'startup-blk':>13}"
        f"{'deliveries':>12}{'req/wake':>10}{'fresh/wake':>12}{'empty':>7}{'empty-fresh':>13}"
    )
    print(header)
    print("-" * len(header))
    for day in report["days"]:
        print(
            f"{day['day']:<12}"
            f"{day['session_starts']:>7}"
            f"{day['session_start_fresh']['median']:>13}"
            f"{day['startup_block_fresh']['median']:>13}"
            f"{day['deliveries']:>12}"
            f"{day['requests_per_delivery']['median']:>10}"
            f"{day['fresh_per_delivery']['median']:>12}"
            f"{day['empty_deliveries']:>7}"
            f"{day['empty_delivery_fresh']:>13}"
        )
    print("")
    print("start-fresh and startup-blk are per-session medians of freshly written tokens.")
    print("req/wake and fresh/wake are medians over delivery segments.")
    print("empty counts deliveries whose drain returned no queue record at all,")
    print("and empty-fresh is what those deliveries wrote into the window.")
    print("")
    print("not counted:")
    for item in report["not_counted"]:
        print(f"  - {item}")


def print_session(report_root, session_id, since, until):
    """One named session in detail: the shape an incident is examined in."""
    target = None
    for path in iter_transcripts(report_root):
        if os.path.splitext(os.path.basename(path))[0] == session_id:
            target = path
            break
    if target is None:
        print(f"fm-supervision-cost: no transcript for session {session_id}", file=sys.stderr)
        return 1
    measurement = measure_file(target, since, until, set())
    if measurement is None:
        print(f"fm-supervision-cost: session {session_id} has no usage records in range", file=sys.stderr)
        return 1
    print(f"session: {measurement.session_id}")
    print(f"project: {measurement.project}")
    print(f"day: {measurement.day}")
    print(f"requests: {measurement.requests}")
    print(f"fresh tokens: {measurement.fresh}")
    print(f"cache-read tokens (carried, not fresh): {measurement.cache_read}")
    print(f"output tokens: {measurement.output}")
    print(f"session-start fresh tokens (first request): {measurement.first_request_fresh}")
    print(f"startup-block fresh tokens: {measurement.startup_fresh}")
    print(f"deliveries: {measurement.deliveries}")
    print(f"  empty deliveries: {measurement.empty_deliveries}")
    print(f"  requests spent on empty deliveries: {measurement.empty_delivery_requests}")
    print(f"  fresh tokens spent on empty deliveries: {measurement.empty_delivery_fresh}")
    print(f"drain calls: {measurement.drain_calls}")
    print(f"  returning no queue record: {measurement.drain_calls_empty}")
    requests = summarize(measurement.segment_requests)
    fresh = summarize(measurement.segment_fresh)
    print(f"requests per delivery: median {requests['median']}, mean {requests['mean']}, max {requests['max']}")
    print(f"fresh tokens per delivery: median {fresh['median']}, mean {fresh['mean']}, total {fresh['total']}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--transcripts", required=True)
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--project")
    parser.add_argument("--session")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.transcripts):
        print(
            f"fm-supervision-cost: no transcript directory at {args.transcripts}",
            file=sys.stderr,
        )
        return 2

    if args.session:
        return print_session(args.transcripts, args.session, args.since, args.until)

    report = measure(args.transcripts, args.since, args.until, args.project)
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
