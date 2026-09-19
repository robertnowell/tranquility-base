#!/usr/bin/env python3
"""Install or stop the guarded delivery worker from the stable deployment checkout."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LABEL = "dev.tranquilitybase.delivery-supervisor"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    domain = f"gui/{os.getuid()}"
    if args.stop:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], check=True)
        return
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()
    common = (ROOT / git("rev-parse", "--git-common-dir")).resolve()
    expected = common.parent / ".claude/worktrees/deployment-main"
    if ROOT != expected or git("status", "--porcelain"):
        raise SystemExit("Install from the clean, persistent deployment-main checkout")
    git("fetch", "-q", "origin")
    git("merge-base", "--is-ancestor", "HEAD", "origin/main")
    for file in ("scripts/delivery.py", "scripts/install-delivery-supervisor.py"):
        if git("hash-object", file) != git("rev-parse", f"origin/main:{file}"):
            raise SystemExit("Deployment supervisor differs from merged main")
    if not shutil.which("gh"):
        raise SystemExit("GitHub CLI is required")
    support = Path.home() / "Library/Application Support/VoiceDispatch"
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    plist = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    body = {"Label": LABEL, "ProgramArguments": [sys.executable, str(ROOT / "scripts/delivery.py"), "supervise"],
            "WorkingDirectory": str(ROOT), "StartInterval": 30, "RunAtLoad": True,
            "ProcessType": "Background", "ThrottleInterval": 30,
            "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")},
            "StandardOutPath": str(support / "delivery-supervisor.log"),
            "StandardErrorPath": str(support / "delivery-supervisor-error.log")}
    for key in ("StandardOutPath", "StandardErrorPath"):
        log = Path(body[key]); log.touch(exist_ok=True); log.chmod(0o600)
    temporary = plist.with_suffix(".tmp")
    temporary.write_bytes(plistlib.dumps(body)); temporary.chmod(0o600); temporary.replace(plist)
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "bootstrap", domain, str(plist)], check=True)
    print("Delivery worker installed: recorded merged work retries after safe handoff; failed source is held.")

if __name__ == "__main__": main()
