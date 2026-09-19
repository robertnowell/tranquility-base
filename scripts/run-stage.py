#!/usr/bin/env python3
"""Stream and retain a stage's output; diagnose and stop its process group on timeout."""
import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def diagnose(group, log):
    try:
        rows = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,pgid=,etime=,stat=,comm="], text=True, timeout=5)
        owned = [row for row in rows.splitlines() if len(row.split()) >= 6 and row.split()[2] == str(group)]
        log.with_suffix(".processes.txt").write_text("PID PPID PGID ELAPSED STATE EXECUTABLE\n" + "\n".join(owned) + "\n")
        if sys.platform == "darwin":
            for row in [r for r in owned if "xctest" in r or ".xctest" in r][:2]:
                pid = row.split()[0]
                subprocess.run(["/usr/bin/sample", pid, "2", "1", "-file", str(log.with_suffix(f".{pid}.sample.txt"))],
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


def run(command, timeout, log):
    if timeout <= 0:
        raise ValueError("stage timeout must be positive")
    log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    interrupted = []
    handlers = {sig: signal.signal(sig, lambda signum, frame: interrupted.append(signum))
                for sig in (signal.SIGINT, signal.SIGTERM)}
    started = time.monotonic()
    status = 1
    with log.open("wb", buffering=0) as output:
        os.chmod(log, 0o600)
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              start_new_session=True, bufsize=0) as child:
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            try:
                while selector.get_map() or child.poll() is None:
                    if interrupted or time.monotonic() - started >= timeout:
                        status = 128 + interrupted[0] if interrupted else 124
                        message = f"\n✗ stage {'interrupted' if interrupted else 'timed out'} after {time.monotonic()-started:.1f}s; log: {log}\n"
                        output.write(message.encode())
                        sys.stderr.write(message); sys.stderr.flush()
                        diagnose(child.pid, log)
                        break
                    for key, _ in selector.select(timeout=0.1):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if chunk:
                            output.write(chunk)
                            sys.stderr.buffer.write(chunk); sys.stderr.buffer.flush()
                        else:
                            selector.unregister(key.fileobj)
                else:
                    status = child.wait()
            finally:
                selector.close()
                stop(child.pid)
                child.wait()
                for sig, handler in handlers.items(): signal.signal(sig, handler)
    print(f"stage finished: exit={status} seconds={time.monotonic()-started:.1f} log={log}", file=sys.stderr, flush=True)
    return status if status >= 0 else 128 - status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command: parser.error("a command is required")
    return run(command, args.timeout, args.log)


if __name__ == "__main__":
    sys.exit(main())
