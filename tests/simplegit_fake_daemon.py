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
    status_count = 0

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
            schedule(
                {
                    "type": "status",
                    "id": request_id,
                    "branch": f"fake-{status_count}",
                    "entries": [{"xy": "??", "path": "sample.txt"}],
                },
                delay,
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
