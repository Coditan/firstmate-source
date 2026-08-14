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

Requests and delivery-arm measurements are deduplicated by ``requestId``, so a
retried request is counted once.

WHAT IS COUNTED
---------------
Activity       requests whose own timestamps fall inside the inclusive date
               bounds, including activity from sessions that started earlier.
Sessions       one transcript file with activity in the window, keyed by its
               session id.
Session start  the fresh tokens of a session's FIRST request (system prompt,
               instruction surface, tool schemas - paid before any work), and
               the startup block, which extends that through the first request
               that reads the session-start digest.  A session that never runs
               the digest has no startup block beyond its first request, and is
               reported that way rather than having the whole session counted as
               startup.  It is attributed only when that true first request is
               inside the date bounds, on the day that request occurred.
Deliveries     one ``<task-notification>`` message: the harness handing a
               completed background task back to the model.  Under a
               background-notify harness that IS the wake.
Segment        every request from one delivery up to the next.  Requests per
               delivery and fresh tokens per delivery are measured over these.
Delivery arms  calls that started the session's wake-delivery wait.  Total arms
               and arms issued beside a drain count arm tool blocks.  Own-arm
               requests count requests whose every tool block is an arm, and
               their freshly written tokens are counted once per request as the
               price of not pairing them.  Arms issued in a request that also
               did non-drain work appear only in the total, because that request
               is not removable and a number that pretended otherwise would be
               the estimate-dressed-as-measurement this tool exists to stop.
Empty delivery a segment that ran the wake drain and got no queue record back:
               the model was woken, paid for the wake, and there was nothing in
               it.  This is the signature of the re-entry defect.

Executable detection is a bounded heuristic over recorded shell command text,
not an execution trace.  It recognizes only the wrapper grammars named in this
engine and returns one of executes, does-not-execute, or unknown.  Unknown forms
are counted but treated as non-executions rather than over-counted.

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
import shlex
import statistics
import sys
from collections import defaultdict

# A drained queue record: epoch, sequence, kind, key, payload.
QUEUE_ROW = re.compile(r"^\d{9,11}\t\d+\t(signal|stale|check|heartbeat)\t")
DRAIN_CALL = "fm-wake-drain.sh"
SESSION_START_CALL = "fm-session-start.sh"
# The delivery arm no longer exists: wake delivery moved out of the harness into
# a service, so no session issues this command any more. The constant stays
# because this engine measures the PAST, and every transcript recorded before
# that move is full of these calls. Deleting it would not make the old cost zero,
# it would make the old cost unmeasurable, and the after-figure only means
# something next to the before-figure. On current transcripts this now counts
# zero, which is the result rather than a bug.
ARM_CALL = "fm-watch-arm.sh"
EXECUTES = "executes"
DOES_NOT_EXECUTE = "does_not_execute"
UNKNOWN = "unknown"
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


def classify_script(command, script):
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return UNKNOWN if script in command else DOES_NOT_EXECUTE
    segments = []
    segment = []
    for token in tokens:
        if token and all(char in ";&|" for char in token):
            if segment:
                segments.append(segment)
                segment = []
        else:
            segment.append(token)
    if segment:
        segments.append(segment)
    outcome = DOES_NOT_EXECUTE
    for words in segments:
        mentions_script = any(os.path.basename(word) == script for word in words)
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]
        if not words:
            continue
        while words:
            wrapper = os.path.basename(words[0])
            if wrapper == "env":
                words = unwrap_env(words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            if wrapper == "timeout":
                words = unwrap_timeout(words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            if wrapper == "nice":
                words = unwrap_nice(words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            if wrapper == "nohup":
                words = unwrap_nohup(words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            if wrapper == "stdbuf":
                words = unwrap_stdbuf(words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            if wrapper in ("command", "exec"):
                words = unwrap_command(wrapper, words[1:])
                if words is None:
                    if mentions_script:
                        outcome = UNKNOWN
                    break
                continue
            break
        if not words:
            continue
        executable = os.path.basename(words[0])
        if executable == script:
            return EXECUTES
        if executable in ("bash", "sh"):
            shell_outcome = classify_shell(words[1:], script)
            if shell_outcome == EXECUTES:
                return EXECUTES
            if shell_outcome == UNKNOWN:
                outcome = UNKNOWN
    return outcome


def classify_shell(words, script):
    index = 0
    no_execute = False
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if word in ("-n", "--noexec"):
            no_execute = True
            index += 1
            continue
        if word in ("--norc", "--noprofile", "-r", "--restricted"):
            index += 1
            continue
        if word in ("-c", "-s") or word.startswith("--") or word.startswith("-"):
            return UNKNOWN if any(script in item for item in words) else DOES_NOT_EXECUTE
        break
    if index >= len(words) or os.path.basename(words[index]) != script:
        return DOES_NOT_EXECUTE
    return DOES_NOT_EXECUTE if no_execute else EXECUTES


def take_option_argument(words, index):
    if index + 1 >= len(words):
        return None
    return index + 2


def unwrap_env(words):
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            index += 1
            continue
        if word in ("-i", "--ignore-environment", "-0", "--null"):
            index += 1
            continue
        if word in ("-u", "--unset", "-C", "--chdir"):
            index = take_option_argument(words, index)
            if index is None:
                return None
            continue
        if word.startswith("--unset=") or word.startswith("--chdir="):
            index += 1
            continue
        if word in ("-S", "--split-string") or word.startswith("--split-string="):
            return None
        if word.startswith("-"):
            return None
        break
    return words[index:] or None


def unwrap_timeout(words):
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if word in ("-s", "--signal", "-k", "--kill-after"):
            index = take_option_argument(words, index)
            if index is None:
                return None
            continue
        if word.startswith("--signal=") or word.startswith("--kill-after="):
            index += 1
            continue
        if word in ("--foreground", "--preserve-status", "-v", "--verbose"):
            index += 1
            continue
        if word.startswith("-"):
            return None
        break
    if index >= len(words):
        return None
    index += 1
    return words[index:] or None


def unwrap_nice(words):
    index = 0
    if index < len(words) and words[index] == "--":
        index += 1
    elif index < len(words) and words[index] in ("-n", "--adjustment"):
        index = take_option_argument(words, index)
        if index is None:
            return None
    elif index < len(words) and words[index].startswith("--adjustment="):
        index += 1
    elif index < len(words) and re.match(r"^-\d+$", words[index]):
        index += 1
    elif index < len(words) and words[index].startswith("-"):
        return None
    return words[index:] or None


def unwrap_nohup(words):
    if words and words[0] == "--":
        words = words[1:]
    elif words and words[0].startswith("-"):
        return None
    return words or None


def unwrap_stdbuf(words):
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if word in ("-i", "-o", "-e", "--input", "--output", "--error"):
            index = take_option_argument(words, index)
            if index is None:
                return None
            continue
        if re.match(r"^-[ioe].+", word) or re.match(
            r"^--(input|output|error)=", word
        ):
            index += 1
            continue
        if word.startswith("-"):
            return None
        break
    return words[index:] or None


def unwrap_command(wrapper, words):
    if wrapper == "command" and words and words[0] in ("-v", "-V"):
        return None
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if wrapper == "exec" and word == "-a":
            index = take_option_argument(words, index)
            if index is None:
                return None
            continue
        if wrapper == "exec" and word in ("-c", "-l"):
            index += 1
            continue
        if word.startswith("-"):
            return None
        break
    return words[index:] or None


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
        self.segment_rows = []
        self.drain_calls = 0
        self.drain_calls_empty = 0
        self.drain_result_bytes = []
        self.drain_result_rows = []
        self.empty_deliveries = 0
        # An empty delivery is a wake that carried nothing. Its requests and its
        # freshly written tokens are the measured price of the defect, kept apart
        # from the wakes that did carry something so a repair can be judged
        # against a number rather than against a feeling.
        self.empty_delivery_requests = 0
        self.empty_delivery_fresh = 0
        self.is_session_start = False
        self.unclassified_commands = 0
        # The delivery arm, counted by the shape of the REQUEST that issued it.
        # A wake costs three model requests under a background-notify harness -
        # drain, arm, close - and the arm is the only one of the three that need
        # not have a request of its own: issued as a second tool block of the
        # message that already issued the drain, it rides along free. So an arm
        # issued ALONE is one removable request, and its freshly written tokens
        # are the price of not pairing it. An arm issued beside the drain is the
        # paired shape and costs nothing extra, which is why the two are counted
        # apart rather than as one "arm calls" number that could not tell a
        # repair from a regression.
        self.arm_calls = 0
        self.arm_calls_paired_with_drain = 0
        self.unpaired_arm_requests = 0
        self.unpaired_arm_fresh = 0


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
    measurement.day = session_day
    measurement.is_session_start = (not since or session_day >= since) and (
        not until or session_day <= until
    )

    # Tool-use id -> True for calls that ran the wake drain, so their results can
    # be classified when they come back a message later.
    drain_calls = {}
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
            measurement.segment_rows.append(segment_rows)
            if segment_drains > 0 and segment_rows == 0:
                measurement.empty_deliveries += 1
                measurement.empty_delivery_requests += segment[0]
                measurement.empty_delivery_fresh += segment[1]
        segment = None
        segment_drains = 0
        segment_rows = 0

    for record in records:
        timestamp = record.get("timestamp") or ""
        day = timestamp[:10]
        if not day:
            continue
        in_range = (not since or day >= since) and (not until or day <= until)

        kind = record.get("type")
        if kind == "assistant":
            message = record.get("message") or {}
            usage = message.get("usage") or {}
            request_id = record.get("requestId")
            this_fresh = 0
            counted_request = False
            if usage and request_id and in_range and request_id not in seen_requests:
                seen_requests.add(request_id)
                counted_request = True
                this_fresh = fresh_tokens(usage)
                measurement.requests += 1
                measurement.fresh += this_fresh
                measurement.cache_read += int(usage.get("cache_read_input_tokens") or 0)
                measurement.output += int(usage.get("output_tokens") or 0)
                if startup_open:
                    measurement.startup_fresh += this_fresh
                    startup_requests += 1
                    if startup_digest_seen or startup_requests >= STARTUP_REQUEST_LIMIT:
                        startup_open = False
                if segment is not None:
                    segment[0] += 1
                    segment[1] += this_fresh
            tool_blocks = 0
            arm_blocks = 0
            drain_blocks = 0
            for block in message.get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool_blocks += 1
                command = (block.get("input") or {}).get("command") or ""
                drain_class = classify_script(command, DRAIN_CALL)
                start_class = classify_script(command, SESSION_START_CALL)
                arm_class = classify_script(command, ARM_CALL)
                if in_range and (
                    drain_class == UNKNOWN
                    or start_class == UNKNOWN
                    or arm_class == UNKNOWN
                ):
                    measurement.unclassified_commands += 1
                if in_range and drain_class == EXECUTES:
                    drain_calls[block.get("id")] = True
                    measurement.drain_calls += 1
                    segment_drains += 1
                    drain_blocks += 1
                if in_range and arm_class == EXECUTES:
                    arm_blocks += 1
                if start_class == EXECUTES:
                    startup_digest_seen = True
                    startup_open = False
            if in_range and counted_request and arm_blocks:
                measurement.arm_calls += arm_blocks
                if drain_blocks:
                    measurement.arm_calls_paired_with_drain += arm_blocks
                elif tool_blocks == arm_blocks:
                    # The whole request exists to start the arm, so pairing it
                    # into the drain's message removes the request outright.
                    # A request that also did other work is not removable and is
                    # deliberately left out rather than counted optimistically.
                    measurement.unpaired_arm_requests += 1
                    measurement.unpaired_arm_fresh += this_fresh
        elif kind == "user":
            content = (record.get("message") or {}).get("content")
            if isinstance(content, str):
                if "<task-notification>" in content:
                    close_segment()
                    if in_range:
                        measurement.deliveries += 1
                        segment = [0, 0]
                continue
            for block in content or []:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                text = tool_result_text(block)
                if in_range and block.get("tool_use_id") in drain_calls:
                    rows = sum(
                        1 for line in text.split("\n") if QUEUE_ROW.match(line)
                    )
                    measurement.drain_result_bytes.append(len(text.encode("utf-8")))
                    measurement.drain_result_rows.append(rows)
                    if rows == 0:
                        measurement.drain_calls_empty += 1
                    segment_rows += rows

    close_segment()
    measurement.first_request_fresh = fresh_tokens(
        next(
            (record.get("message") or {}).get("usage") or {}
            for record in records
            if record.get("type") == "assistant"
            and (record.get("message") or {}).get("usage")
            and record.get("requestId")
        )
    )
    if measurement.requests == 0 and not measurement.is_session_start:
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
    paths = []
    activity_days = set()
    for path in iter_transcripts(root):
        if project_filter and project_filter not in os.path.dirname(path):
            continue
        paths.append(path)
        for record in read_records(path):
            day = (record.get("timestamp") or "")[:10]
            if day and (not since or day >= since) and (not until or day <= until):
                activity_days.add(day)

    by_day = defaultdict(list)
    active_sessions = set()
    seen_requests = set()
    for day in sorted(activity_days):
        for path in paths:
            measurement = measure_file(path, day, day, seen_requests)
            if measurement is None:
                continue
            measurement.day = day
            by_day[day].append(measurement)
            if measurement.requests:
                active_sessions.add(measurement.session_id)

    days = []
    for day in sorted(by_day):
        group = by_day[day]
        segment_requests = [n for m in group for n in m.segment_requests]
        segment_fresh = [n for m in group for n in m.segment_fresh]
        days.append(
            {
                "day": day,
                "session_starts": sum(m.is_session_start for m in group),
                "requests": sum(m.requests for m in group),
                "fresh_tokens": sum(m.fresh for m in group),
                "cache_read_tokens": sum(m.cache_read for m in group),
                "output_tokens": sum(m.output for m in group),
                "session_start_fresh": summarize(
                    [
                        m.first_request_fresh
                        for m in group
                        if m.is_session_start and m.first_request_fresh is not None
                    ]
                ),
                "startup_block_fresh": summarize(
                    [m.startup_fresh for m in group if m.is_session_start]
                ),
                "deliveries": sum(m.deliveries for m in group),
                "requests_per_delivery": summarize(segment_requests),
                "fresh_per_delivery": summarize(segment_fresh),
                "drain_calls": sum(m.drain_calls for m in group),
                "drain_calls_empty": sum(m.drain_calls_empty for m in group),
                "arm_calls": sum(m.arm_calls for m in group),
                "arm_calls_paired_with_drain": sum(
                    m.arm_calls_paired_with_drain for m in group
                ),
                "unpaired_arm_requests": sum(
                    m.unpaired_arm_requests for m in group
                ),
                "unpaired_arm_fresh": sum(m.unpaired_arm_fresh for m in group),
                "empty_deliveries": sum(m.empty_deliveries for m in group),
                "empty_delivery_requests": sum(
                    m.empty_delivery_requests for m in group
                ),
                "empty_delivery_fresh": sum(m.empty_delivery_fresh for m in group),
                "unclassified_commands": sum(
                    m.unclassified_commands for m in group
                ),
                "requests_per_delivery_distribution": {
                    str(value): {
                        "deliveries": sum(
                            1
                            for m in group
                            for requests in m.segment_requests
                            if requests == value
                        ),
                        "carried_record": sum(
                            1
                            for m in group
                            for requests, rows in zip(m.segment_requests, m.segment_rows)
                            if requests == value and rows > 0
                        ),
                    }
                    for value in sorted(set(segment_requests))
                },
            }
        )

    distribution_measurements = []
    distribution_seen = set()
    for path in paths:
        measurement = measure_file(path, since, until, distribution_seen)
        if measurement is not None:
            distribution_measurements.append(measurement)
    distribution = defaultdict(lambda: {"deliveries": 0, "carried_record": 0})
    drain_bytes = []
    drain_rows = []
    for measurement in distribution_measurements:
        drain_bytes.extend(measurement.drain_result_bytes)
        drain_rows.extend(measurement.drain_result_rows)
        for requests, rows in zip(
            measurement.segment_requests, measurement.segment_rows
        ):
            distribution[str(requests)]["deliveries"] += 1
            distribution[str(requests)]["carried_record"] += rows > 0

    sorted_drain_bytes = sorted(drain_bytes)
    p99_index = max(0, (len(sorted_drain_bytes) * 99 + 99) // 100 - 1)

    return {
        "unit": "fresh tokens = input_tokens + cache_creation_input_tokens, per unique requestId",
        "window_semantics": (
            "activity is bounded by each request timestamp; session starts are "
            "counted only when the true first request is in the window"
        ),
        "not_counted": [
            "harnesses other than Claude Code, which keep no equivalent local usage record",
            "days whose transcripts the provider has already rolled off",
            "currency cost, which needs a price list this tool does not pin",
            "executions not recognized by the bounded shell-wrapper heuristic",
        ],
        "transcripts_root": root,
        "sessions": len(active_sessions),
        "days": days,
        "unclassified_commands": sum(
            day["unclassified_commands"] for day in days
        ),
        "requests_per_delivery_distribution": dict(distribution),
        "drain_results": {
            "count": len(drain_bytes),
            "median_bytes": statistics.median(drain_bytes) if drain_bytes else 0,
            "p99_bytes": sorted_drain_bytes[p99_index] if drain_bytes else 0,
            "max_bytes": max(drain_bytes) if drain_bytes else 0,
            "max_rows": max(drain_rows) if drain_rows else 0,
        },
    }


def print_report(report):
    print(f"unit: {report['unit']}")
    print(f"window: {report['window_semantics']}")
    print(f"transcripts: {report['transcripts_root']}")
    print(f"sessions measured: {report['sessions']}")
    print(f"unclassified relevant commands: {report['unclassified_commands']}")
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
    arm_calls = sum(day["arm_calls"] for day in report["days"])
    paired = sum(day["arm_calls_paired_with_drain"] for day in report["days"])
    unpaired = sum(day["unpaired_arm_requests"] for day in report["days"])
    unpaired_fresh = sum(day["unpaired_arm_fresh"] for day in report["days"])
    print(f"delivery arm calls: {arm_calls}")
    print(f"  arm calls issued beside the drain: {paired}")
    print(f"  requests containing only arm calls: {unpaired}")
    print(f"  fresh tokens those arm-only requests wrote: {unpaired_fresh}")
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
    print(f"delivery arm calls: {measurement.arm_calls}")
    print(
        "  arm calls issued beside the drain: "
        f"{measurement.arm_calls_paired_with_drain}"
    )
    print(f"  requests containing only arm calls: {measurement.unpaired_arm_requests}")
    print(f"  fresh tokens those arm-only requests wrote: {measurement.unpaired_arm_fresh}")
    print(f"unclassified relevant commands: {measurement.unclassified_commands}")
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
