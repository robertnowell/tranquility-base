#!/usr/bin/env python3
"""Update only the stable deployment checkout, excluding concurrent builds and activation."""
import fcntl
import importlib.util
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    def git(*args, cwd=ROOT):
        return subprocess.check_output(["git", *args], cwd=cwd, text=True, timeout=60).strip()
    common = (ROOT / git("rev-parse", "--git-common-dir")).resolve()
    checkout = common.parent / ".claude/worktrees/deployment-main"
    remote = git("remote", "get-url", "origin", cwd=checkout).removesuffix(".git")
    if remote not in ("https://github.com/robertnowell/tranquility-base", "git@github.com:robertnowell/tranquility-base"):
        raise SystemExit("Unexpected deployment repository")
    git("fetch", "-q", "origin", cwd=checkout)
    target = git("rev-parse", "origin/main", cwd=checkout)
    cache = Path.home() / "Library/Caches/TranquilityBase/prepared-dev"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / "build.lock").open("a+") as build:
        try:
            fcntl.flock(build, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("A build is using deployment tooling; retry after it finishes")
        spec = importlib.util.spec_from_file_location("state", checkout / "scripts/deployment-state.py")
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        state = module.DeploymentState(Path.home() / "Library/Application Support/VoiceDispatch", "/tmp/tb-relaunch.lock")
        token = state.acquire(os.getpid())
        try:
            if git("status", "--porcelain", cwd=checkout): raise SystemExit("Deployment checkout is dirty")
            git("checkout", "--detach", target, cwd=checkout)
            print("Deployment tooling updated to", target)
        finally:
            state.unlock(os.getpid(), token)


if __name__ == "__main__": main()
