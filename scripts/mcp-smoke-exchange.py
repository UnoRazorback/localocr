#!/usr/bin/env python3
"""Run a bounded MCP stdio exchange without closing stdin prematurely."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import subprocess
import sys
import time


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--expect-id", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a server command is required after --")
    return arguments


def _stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main() -> int:
    arguments = _arguments()
    expected_ids = set(arguments.expect_id)
    observed_ids: set[str] = set()
    request_bytes = sys.stdin.buffer.read()
    process = subprocess.Popen(
        arguments.command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None

    stdout = bytearray()
    stderr = bytearray()
    pending_line = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    deadline = time.monotonic() + arguments.timeout
    stdin_closed = False

    try:
        process.stdin.write(request_bytes)
        process.stdin.flush()
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            events = selector.select(min(remaining, 0.1))
            if not events:
                if process.poll() is not None:
                    break
                continue
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "stderr":
                    stderr.extend(chunk)
                    continue

                stdout.extend(chunk)
                pending_line.extend(chunk)
                while b"\n" in pending_line:
                    raw_line, _, remainder = pending_line.partition(b"\n")
                    pending_line = bytearray(remainder)
                    try:
                        value = json.loads(raw_line)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        continue
                    if isinstance(value, dict) and "id" in value:
                        observed_ids.add(str(value["id"]))

            if expected_ids <= observed_ids and not stdin_closed:
                process.stdin.close()
                stdin_closed = True

            if process.poll() is not None and not selector.get_map():
                break
    finally:
        if not stdin_closed:
            process.stdin.close()
        selector.close()

    timed_out = process.poll() is None
    if timed_out:
        _stop(process)
    else:
        process.wait()

    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    if timed_out:
        print("MCP stdio exchange timed out", file=sys.stderr)
        return 1
    missing_ids = sorted(expected_ids - observed_ids)
    if missing_ids:
        print("MCP stdio exchange ended before all expected responses", file=sys.stderr)
        return 1
    if process.returncode != 0:
        print("MCP stdio server exited unsuccessfully", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
