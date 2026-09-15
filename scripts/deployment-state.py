#!/usr/bin/env python3
"""Durable preview ownership shared by every local app mutation."""

import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import secrets
import sys
import tempfile
import time


class Blocked(Exception):
    pass


class DeploymentState:
    def __init__(self, state_dir, lock_dir, now=time.time):
        self.state_dir = Path(state_dir)
        self.lock_dir = Path(lock_dir)
        self.path = self.state_dir / "deployment.json"
        self.now = now

    @contextmanager
    def transaction(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        # This short kernel lock serializes state/lock metadata operations. The
        # existing mkdir lock remains held by the shell during the whole deploy.
        with open(self.state_dir / "deployment.lock", "a+") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def read(self):
        if not self.path.exists():
            return {"version": 1, "preview": None, "pending": []}
        try:
            state = json.loads(self.path.read_text())
            if state.get("version") != 1 or not isinstance(state.get("pending"), list) or "preview" not in state:
                raise ValueError("unsupported state")
            if not all(isinstance(p, dict) for p in state["pending"]):
                raise ValueError("invalid pending request")
            preview = state.get("preview")
            if preview is not None:
                if not all(k in preview for k in ("owner", "token", "sha", "channel", "expires_at")):
                    raise ValueError("incomplete preview")
                if not isinstance(preview["expires_at"], (int, float)) or not math.isfinite(preview["expires_at"]):
                    raise ValueError("invalid expiry")
                if not all(isinstance(preview[k], str) and preview[k] for k in ("owner", "token", "sha", "channel")):
                    raise ValueError("invalid preview identity")
                if len(preview["sha"]) != 40 or any(c not in "0123456789abcdef" for c in preview["sha"]) or preview["channel"] not in ("dev", "prod"):
                    raise ValueError("invalid preview target")
            return state
        except (ValueError, TypeError, AttributeError) as error:
            raise Blocked(f"deployment state needs repair: {error}") from error

    def write(self, state):
        fd, name = tempfile.mkstemp(prefix=".deployment-", dir=self.state_dir)
        try:
            with os.fdopen(fd, "w") as out:
                json.dump(state, out, indent=2)
                out.write("\n")
                out.flush()
                os.fsync(out.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def lock_owner(self):
        try:
            return json.loads((self.lock_dir / "owner.json").read_text())
        except (FileNotFoundError, ValueError):
            return None

    def acquire(self, pid, token=""):
        with self.transaction():
            owner = self.lock_owner()
            if token and owner == {"pid": pid, "token": token}:
                return token  # install-dev execs switch-app without changing pid.
            if self.lock_dir.exists():
                if self.lock_dir.is_symlink() or not self.lock_dir.is_dir():
                    raise Blocked("app mutation lock is not a directory")
                try:
                    holder = int((self.lock_dir / "pid").read_text().strip())
                except (FileNotFoundError, ValueError):
                    holder = 0
                if holder > 0 and self.alive(holder):
                    raise Blocked(f"another app mutation (pid {holder}) is in progress")
                # An older writer may be between mkdir and publishing its pid.
                # Missing metadata is never immediate permission to steal it.
                if holder == 0 and self.now() - self.lock_dir.stat().st_mtime < 120:
                    raise Blocked("app mutation lock is initializing; retry later")
                if any(p.name not in {"pid", "owner.json"} for p in self.lock_dir.iterdir()):
                    raise Blocked("app mutation lock contains unknown state; inspect it")
                for path in self.lock_dir.iterdir():
                    path.unlink()
                self.lock_dir.rmdir()
            try:
                self.lock_dir.mkdir(mode=0o700)
            except FileExistsError as error:
                raise Blocked("another app mutation acquired the lock") from error
            token = secrets.token_hex(16)
            (self.lock_dir / "pid").write_text(str(pid) + "\n")
            (self.lock_dir / "owner.json").write_text(json.dumps({"pid": pid, "token": token}))
            return token

    def require_lock(self, pid, token):
        if not token or self.lock_owner() != {"pid": pid, "token": token}:
            raise Blocked("this process does not own the app mutation lock")

    def unlock(self, pid, token):
        with self.transaction():
            self.require_lock(pid, token)
            (self.lock_dir / "owner.json").unlink()
            (self.lock_dir / "pid").unlink()
            self.lock_dir.rmdir()

    def active_preview(self, state):
        preview = state["preview"]
        return preview if preview and preview["expires_at"] > self.now() else None

    def reserve(self, pid, lock_token, owner, sha, channel, minutes, preview_token=""):
        with self.transaction():
            self.require_lock(pid, lock_token)
            state = self.read()
            current = self.active_preview(state)
            if current and current["token"] != preview_token:
                raise Blocked(f"preview is reserved by {current['owner']} until {current['expires_at']}")
            # Renewals/handoffs get a fresh token; a stale release cannot clear it.
            token = secrets.token_hex(16)
            state["preview"] = {
                "owner": owner, "sha": sha, "channel": channel, "token": token,
                "expires_at": self.now() + minutes * 60,
            }
            self.write(state)
            return token

    def release(self, pid, lock_token, preview_token):
        with self.transaction():
            self.require_lock(pid, lock_token)
            state = self.read()
            if not state["preview"] or state["preview"]["token"] != preview_token:
                raise Blocked("preview token is stale or does not own this reservation")
            state["preview"] = None
            self.write(state)

    def authorize(self, pid, lock_token, operation, sha, channel, owner, preview_token="", unmerged=False):
        with self.transaction():
            self.require_lock(pid, lock_token)
            state = self.read()
            preview = self.active_preview(state)
            allowed = preview and preview["token"] == preview_token and preview["sha"] == sha and preview["channel"] == channel
            if (preview and not allowed) or (unmerged and not allowed):
                reason = f"preview reserved by {preview['owner']}" if preview else "unmerged source needs a preview reservation"
                request = {"operation": operation, "sha": sha, "channel": channel,
                           "retry_owner": owner, "reason": reason, "requested_at": self.now()}
                state["pending"] = [p for p in state["pending"] if (p.get("operation"), p.get("sha"), p.get("channel")) != (operation, sha, channel)]
                state["pending"].append(request)
                self.write(state)
                raise Blocked(f"{reason}; deployment pending for {owner}: {sha}")

    def status(self):
        with self.transaction():
            state = self.read()
            if state["preview"]:
                state["preview"]["active"] = self.active_preview(state) is not None
                state["preview"].pop("token")
            return state


def full_sha(value):
    if len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
        raise argparse.ArgumentTypeError("a full lowercase commit SHA is required")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("lock", "unlock", "authorize"):
        p = sub.add_parser(name)
        p.add_argument("--pid", required=True, type=int)
        p.add_argument("--lock-token", default="")
        if name == "authorize":
            p.add_argument("--operation", required=True)
            p.add_argument("--sha", required=True, type=full_sha)
            p.add_argument("--channel", required=True, choices=("dev", "prod"))
            p.add_argument("--owner", required=True)
            p.add_argument("--preview-token", default="")
            p.add_argument("--unmerged", choices=("0", "1"), default="0")
    reserve = sub.add_parser("reserve")
    reserve.add_argument("--owner", required=True)
    reserve.add_argument("--sha", required=True, type=full_sha)
    reserve.add_argument("--channel", default="dev", choices=("dev", "prod"))
    reserve.add_argument("--minutes", type=int, default=120)
    reserve.add_argument("--preview-token", default="")
    release = sub.add_parser("release")
    release.add_argument("--preview-token", required=True)
    sub.add_parser("status")
    args = parser.parse_args()
    state = DeploymentState(Path.home() / "Library/Application Support/VoiceDispatch", "/tmp/tb-relaunch.lock")
    try:
        if args.command == "status":
            print(json.dumps(state.status(), indent=2))
        elif args.command == "lock":
            if args.pid <= 0 or not state.alive(args.pid):
                raise Blocked("lock owner must be a living process")
            print(state.acquire(args.pid, args.lock_token))
        elif args.command == "unlock":
            state.unlock(args.pid, args.lock_token)
        elif args.command == "authorize":
            state.authorize(args.pid, args.lock_token, args.operation, args.sha, args.channel,
                            args.owner, args.preview_token, args.unmerged == "1")
        else:
            if args.command == "reserve" and not 1 <= args.minutes <= 1440:
                parser.error("preview duration must be between 1 and 1440 minutes")
            pid = os.getpid()
            token = state.acquire(pid)
            try:
                if args.command == "reserve":
                    print(state.reserve(pid, token, args.owner, args.sha, args.channel,
                                        args.minutes, args.preview_token))
                else:
                    state.release(pid, token, args.preview_token)
                    print("Preview released. Pending deployments remain recorded for their retry owner.")
            finally:
                state.unlock(pid, token)
    except (Blocked, OSError) as error:
        print(f"deployment deferred: {error}", file=sys.stderr)
        return 75
    return 0


if __name__ == "__main__":
    sys.exit(main())
