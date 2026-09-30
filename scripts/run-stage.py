#!/usr/bin/env python3
"""Stream and retain a stage's output; diagnose and stop its process group on timeout.

With --start-marker, a stage that goes quiet for --start-quiet seconds BEFORE
the marker appears is a stall before any test ran, and is retried once. Seen
three times on 30 Sep 2026 (runs 36737212972, 36743519952): the test bundle
built, swift-test sat asleep, and the XCTest runner was never launched. No test
had run, so a retry cannot hide a failure; a stall AFTER the marker is still
the ordinary timeout.
"""
import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def diagnose(group, log, suffix=""):
    try:
        rows = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,pgid=,etime=,stat=,comm="], text=True, timeout=5)
        owned = [row for row in rows.splitlines() if len(row.split()) >= 6 and row.split()[2] == str(group)]
        log.with_suffix(f"{suffix}.processes.txt").write_text("PID PPID PGID ELAPSED STATE EXECUTABLE\n" + "\n".join(owned) + "\n")
        if sys.platform == "darwin":
            # swift-test too: in the pre-start stall it is the only process left.
            for row in [r for r in owned if "xctest" in r or "swift-test" in r][:2]:
                pid = row.split()[0]
                subprocess.run(["/usr/bin/sample", pid, "2", "1", "-file", str(log.with_suffix(f"{suffix}.{pid}.sample.txt"))],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"stage diagnostics incomplete: {type(error).__name__}", file=sys.stderr, flush=True)


def stop(group):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            # Fail closed if the group still has a live member. Darwin may
            # reject the final cleanup signal after every member has exited.
            rows = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True, timeout=5)
            if any(r.split()[0] == str(group) and not r.split()[1].startswith("Z")
                   for r in rows.splitlines() if len(r.split()) >= 2):
                raise
            return
        if sig == signal.SIGTERM:
            time.sleep(1)


STALLED_BEFORE_START = -1


def attempt(command, timeout, log, output, interrupted, marker, quiet, attempt_no):
    """One run of the command. Returns its status, or STALLED_BEFORE_START."""
    started = time.monotonic()
    last_output = started
    seen = b""
    marked = marker is None
    status = 1
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          start_new_session=True, bufsize=0) as child:
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        try:
            while selector.get_map() or child.poll() is None:
                now = time.monotonic()
                if not marked and quiet and now - last_output >= quiet:
                    message = (f"\n\u2717 stage quiet for {now-last_output:.0f}s before any "
                               f"{marker!r} (attempt {attempt_no}); no test ran\n")
                    output.write(message.encode())
                    sys.stderr.write(message); sys.stderr.flush()
                    diagnose(child.pid, log, f".stall{attempt_no}")
                    status = STALLED_BEFORE_START
                    break
                if interrupted or now - started >= timeout:
                    status = 128 + interrupted[0] if interrupted else 124
                    message = f"\n\u2717 stage {'interrupted' if interrupted else 'timed out'} after {now-started:.1f}s; log: {log}\n"
                    output.write(message.encode())
                    sys.stderr.write(message); sys.stderr.flush()
                    diagnose(child.pid, log)
                    break
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if chunk:
                        last_output = time.monotonic()
                        output.write(chunk)
                        sys.stderr.buffer.write(chunk); sys.stderr.buffer.flush()
                        if not marked:
                            seen = (seen + chunk)[-4096:]
                            marked = marker.encode() in seen
                    else:
                        selector.unregister(key.fileobj)
            else:
                status = child.wait()
        finally:
            selector.close()
            stop(child.pid)
            child.wait()
    return status


def run(command, timeout, log, marker=None, quiet=0, retries=1):
    if timeout <= 0:
        raise ValueError("stage timeout must be positive")
    log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    interrupted = []
    handlers = {sig: signal.signal(sig, lambda signum, frame: interrupted.append(signum))
                for sig in (signal.SIGINT, signal.SIGTERM)}
    started = time.monotonic()
    try:
        with log.open("wb", buffering=0) as output:
            os.chmod(log, 0o600)
            for number in range(1, retries + 2):
                status = attempt(command, timeout, log, output, interrupted, marker, quiet, number)
                if status != STALLED_BEFORE_START:
                    break
                if number <= retries:
                    message = f"\u21bb retrying: attempt {number + 1}\n"
                    output.write(message.encode()); sys.stderr.write(message); sys.stderr.flush()
            if status == STALLED_BEFORE_START:
                status = 124
    finally:
        for sig, handler in handlers.items(): signal.signal(sig, handler)
    print(f"stage finished: exit={status} seconds={time.monotonic()-started:.1f} log={log}", file=sys.stderr, flush=True)
    return status if status >= 0 else 128 - status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--start-marker", help="output that shows the work has begun")
    parser.add_argument("--start-quiet", type=float, default=0,
                        help="seconds of silence before the marker that count as a stall")
    parser.add_argument("--start-retries", type=int, default=1)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command: parser.error("a command is required")
    return run(command, args.timeout, args.log, args.start_marker, args.start_quiet, args.start_retries)


if __name__ == "__main__":
    sys.exit(main())
