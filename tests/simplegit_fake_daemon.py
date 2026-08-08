#!/usr/bin/env python3
"""Protocol-5 simplegit daemon fixture for capability and UI-race tests."""

import json
import os
import sys
import threading
import time


output_lock = threading.Lock()


def emit(message, delay_ms=0):
    if delay_ms:
        time.sleep(delay_ms / 1000.0)
    encoded = json.dumps(message, separators=(",", ":"))
    with output_lock:
        sys.stdout.write(encoded + "\n")
        sys.stdout.flush()


def schedule(message, delay_ms):
    if delay_ms:
        threading.Thread(target=emit, args=(message, delay_ms)).start()
    else:
        emit(message)


def delays_from_env(name):
    raw = os.environ.get(name, "")
    return [int(value) for value in raw.split(",") if value]


def main():
    log_path = os.environ.get("SIMPLEGIT_FAKE_LOG", "")
    file_op_delay = int(os.environ.get("SIMPLEGIT_FAKE_FILE_OP_DELAY_MS", "0"))
    commit_delay = int(os.environ.get("SIMPLEGIT_FAKE_COMMIT_DELAY_MS", "0"))
    status_delays = delays_from_env("SIMPLEGIT_FAKE_STATUS_DELAYS")
    status_entries = []
    raw_status_entries = os.environ.get("SIMPLEGIT_FAKE_STATUS_ENTRIES", "")
    if raw_status_entries:
        decoded = json.loads(raw_status_entries)
        if isinstance(decoded, list) and all(isinstance(value, list) for value in decoded):
            status_entries = decoded
    status_count = 0
    show_count = 0
    show_delays = delays_from_env("SIMPLEGIT_FAKE_SHOW_DELAYS")
    view_delay = int(os.environ.get("SIMPLEGIT_FAKE_VIEW_DELAY_MS", "0"))
    hunks_delay = int(os.environ.get("SIMPLEGIT_FAKE_HUNKS_DELAY_MS", "0"))
    blame_line_delay = int(os.environ.get("SIMPLEGIT_FAKE_BLAME_LINE_DELAY_MS", "0"))
    blame_file_lines = int(os.environ.get("SIMPLEGIT_FAKE_BLAME_LINES", "10"))
    uncommitted_lnum = int(os.environ.get("SIMPLEGIT_FAKE_UNCOMMITTED_LNUM", "0"))
    blame_commit = {
        "sha": "deadbeef" * 5,
        "author": "Alice",
        "email": "alice@example.com",
        "time": int(os.environ.get("SIMPLEGIT_FAKE_BLAME_TIME", "1700000000")),
        "summary": "initial import",
    }
    branch_count = 0
    branch_delays = delays_from_env("SIMPLEGIT_FAKE_BRANCH_DELAYS")
    branch_heads = [
        value
        for value in os.environ.get("SIMPLEGIT_FAKE_BRANCH_HEADS", "").split(",")
        if value
    ]
    hunks = []
    raw_hunks = os.environ.get("SIMPLEGIT_FAKE_HUNKS", "")
    if raw_hunks:
        decoded = json.loads(raw_hunks)
        if isinstance(decoded, list):
            hunks = decoded

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            emit({"type": "error", "id": 0, "message": "bad json"})
            continue

        if log_path:
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(json.dumps(request, separators=(",", ":")) + "\n")

        kind = request.get("type", "")
        request_id = request.get("id", 0)
        if kind == "version":
            reply = {
                "type": "version",
                "id": request_id,
                "version": "protocol-test",
                "protocol": 5,
            }
            if not os.environ.get("SIMPLEGIT_FAKE_OMIT_CAPABILITIES"):
                caps = os.environ.get(
                    "SIMPLEGIT_FAKE_CAPS", "repository_file_ops"
                )
                reply["capabilities"] = {
                    cap: True for cap in caps.split(",") if cap
                }
            emit(reply)
        elif kind == "status":
            status_count += 1
            delay = (
                status_delays[status_count - 1]
                if status_count <= len(status_delays)
                else 0
            )
            entries = [{"xy": "??", "path": "sample.txt"}]
            if status_entries:
                entries = status_entries[min(status_count - 1, len(status_entries) - 1)]
            schedule(
                {
                    "type": "status",
                    "id": request_id,
                    "branch": f"fake-{status_count}",
                    "entries": entries,
                },
                delay,
            )
        elif kind == "show":
            show_count += 1
            delay = (
                show_delays[show_count - 1]
                if show_count <= len(show_delays)
                else view_delay
            )
            schedule(
                {
                    "type": "show",
                    "id": request_id,
                    "lines": [f"commit fake-{show_count}", "", "    subject"],
                },
                delay,
            )
        elif kind == "cat":
            schedule(
                {
                    "type": "cat",
                    "id": request_id,
                    "lines": ["cat line one", "cat line two"],
                },
                view_delay,
            )
        elif kind == "log":
            schedule(
                {
                    "type": "log",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "entries": [
                        {
                            "sha": "deadbeef" * 5,
                            "author": "Alice",
                            "time": 1700000000,
                            "subject": "initial import",
                        }
                    ],
                },
                view_delay,
            )
        elif kind == "graph_log":
            schedule(
                {
                    "type": "graph_log",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "skip": request.get("skip", 0),
                    "rows": [
                        {
                            "graph": "* ",
                            "sha": "deadbeef" * 5,
                            "date": "2026-08-08",
                            "author": "Alice",
                            "refs": "",
                            "subject": "initial import",
                        }
                    ],
                },
                view_delay,
            )
        elif kind == "blame_line":
            lnum = request.get("lnum", 0)
            body = dict(blame_commit)
            if lnum == uncommitted_lnum:
                body = {
                    "sha": "0" * 40,
                    "author": "Not Committed Yet",
                    "email": "",
                    "time": blame_commit["time"],
                    "summary": "uncommitted",
                }
            schedule(
                dict(
                    {
                        "type": "blame_line",
                        "id": request_id,
                        "path": request.get("path", ""),
                        "lnum": lnum,
                    },
                    **body,
                ),
                blame_line_delay,
            )
        elif kind == "blame":
            emit(
                {
                    "type": "blame",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "lines": [blame_commit["sha"]] * blame_file_lines,
                    "commits": {
                        blame_commit["sha"]: {
                            key: blame_commit[key]
                            for key in ("author", "email", "time", "summary")
                        }
                    },
                }
            )
        elif kind == "branch":
            branch_count += 1
            # SIMPLEGIT_FAKE_BRANCH_HEADS/_DELAYS answer the nth branch read
            # differently, which is how a test holds one read on the wire while
            # a checkout-style event asks the question again.
            head = os.environ.get("SIMPLEGIT_FAKE_HEAD", "fake-branch")
            if branch_heads:
                head = branch_heads[min(branch_count - 1, len(branch_heads) - 1)]
            delay = (
                branch_delays[branch_count - 1]
                if branch_count <= len(branch_delays)
                else 0
            )
            schedule(
                {
                    "type": "branch",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "head": head,
                    "ahead": int(os.environ.get("SIMPLEGIT_FAKE_AHEAD", "0")),
                    "behind": int(os.environ.get("SIMPLEGIT_FAKE_BEHIND", "0")),
                },
                delay,
            )
        elif kind == "hunks":
            schedule(
                {
                    "type": "hunks",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "hunks": hunks,
                },
                hunks_delay,
            )
        elif kind == "file_op":
            schedule(
                {
                    "type": "file_op",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "op": request.get("op", ""),
                },
                file_op_delay,
            )
        elif kind == "commit":
            schedule(
                {
                    "type": "commit",
                    "id": request_id,
                    "path": request.get("path", ""),
                    "sha": "fake123",
                    "subject": request.get("message", "").split("\n", 1)[0],
                    "summary": "fake commit",
                },
                commit_delay,
            )
        else:
            emit(
                {
                    "type": "error",
                    "id": request_id,
                    "message": "unsupported test request: " + kind,
                }
            )


if __name__ == "__main__":
    main()
