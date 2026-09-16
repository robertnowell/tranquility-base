#!/usr/bin/env python3
"""Observe actual PR merges and retain supervised deployment intent."""

import argparse
import fcntl
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "robertnowell/tranquility-base"
spec = importlib.util.spec_from_file_location("deployment_state", ROOT / "scripts/deployment-state.py")
state_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state_module)
Blocked = state_module.Blocked


def run_install(command, **kwargs):
    """Stop the whole build/install process group on timeout or interruption."""
    timeout = kwargs.pop("timeout")
    with subprocess.Popen(command, start_new_session=True, **kwargs) as child:
        try:
            return subprocess.CompletedProcess(command, child.wait(timeout=timeout))
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
            finally:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            raise


class Delivery:
    def __init__(self, state, root=ROOT, run=subprocess.run, now=time.time):
        self.state, self.root, self.run, self.now = state, Path(root), run, now
        self.path = state.state_dir / "delivery.json"

    def read(self):
        if not self.path.exists():
            return {"version": 1, "requests": {}}
        try:
            result = json.loads(self.path.read_text())
            if result.get("version") != 1 or not isinstance(result.get("requests"), dict):
                raise ValueError("unsupported state")
            if not all(isinstance(v, dict) for v in result["requests"].values()):
                raise ValueError("invalid request")
            return result
        except (ValueError, TypeError, AttributeError) as error:
            raise Blocked(f"delivery state needs repair: {error}") from error

    def update(self, pr, **fields):
        with self.state.transaction():
            data = self.read()
            item = data["requests"].setdefault(str(pr), {"pr": pr, "status": "requested", "requested_at": self.now()})
            item.update(fields, updated_at=self.now())
            fd, temporary = tempfile.mkstemp(prefix=".delivery-", dir=self.state.state_dir)
            try:
                with os.fdopen(fd, "w") as out:
                    json.dump(data, out, indent=2)
                    out.write("\n")
                    out.flush()
                    os.fsync(out.fileno())
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            return dict(item)

    def command(self, *args):
        return self.run(list(args), cwd=self.root, check=True, text=True,
                        capture_output=True, timeout=45, env=dict(os.environ, LC_ALL="C")).stdout.strip()

    def observe(self, pr, owner):
        # Write BEFORE any network access, so even an interrupted query has an
        # explicit retry owner. Preserve prior merge/runtime evidence on errors.
        self.update(pr, retry_owner=owner)
        observed = json.loads(self.command(
            "gh", "pr", "view", str(pr), "--repo", REPOSITORY, "--json",
            "state,mergeCommit,headRefOid,autoMergeRequest,labels,url,mergedAt"))
        if observed["state"] != "MERGED":
            queued = observed.get("autoMergeRequest") or any(
                label["name"] == "merge-queue" for label in observed.get("labels", []))
            status = "closed" if observed["state"] == "CLOSED" else "queued" if queued else "awaiting_merge"
            return self.update(pr, status=status, head_sha=observed["headRefOid"],
                               url=observed["url"], last_error=None)
        merged = state_module.full_sha(observed["mergeCommit"]["oid"])
        self.update(pr, status="merged", merged_sha=merged, merged_at=observed["mergedAt"],
                    url=observed["url"], last_error=None)
        remote = self.command("git", "remote", "get-url", "origin")
        if remote.removesuffix(".git") not in (f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}"):
            raise Blocked("deployment checkout does not use the expected origin")
        self.command("git", "fetch", "-q", "origin")
        self.command("git", "merge-base", "--is-ancestor", merged, "origin/main")
        # Coalesce an older merged request into the current main, but record both
        # identities. The requested squash merge must be contained in the target.
        target = state_module.full_sha(self.command("git", "rev-parse", "origin/main"))
        return self.update(pr, status="deployment_pending", target_sha=target,
                           last_error=None)

    def step(self, pr, owner):
        self.state.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(self.state.state_dir / f"delivery-pr-{pr}.lock", "a") as lock:
            os.chmod(lock.name, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise Blocked(f"another watcher is checking PR {pr}; its intent remains recorded") from error
            return self._step(pr, owner)

    def _step(self, pr, owner):
        item = self.observe(pr, owner)
        if item["status"] != "deployment_pending":
            return item
        target = item["target_sha"]
        with self.state.transaction():
            previous = self.state.read().get("running")
        if previous and self.receipt_still_running(previous):
            # This request is delivered once its merge is in a verified main
            # build. Later main movement must not invalidate that completion.
            try:
                self.command("git", "merge-base", "--is-ancestor", item["merged_sha"], previous["sha"])
                self.command("git", "merge-base", "--is-ancestor", previous["sha"], "origin/main")
            except subprocess.CalledProcessError as error:
                if error.returncode != 1:
                    raise
            else:
                return self.update(pr, status="running", target_sha=previous["sha"],
                                   receipt=previous, last_error=None)
        # A current checkout is necessary: relaunch and its shared helpers are
        # the policy. Never build a new app with an old deployment driver.
        for path in ("scripts/relaunch.sh", "scripts/build-clean.sh", "scripts/lib/deployment.sh",
                     "scripts/deployment-state.py", "scripts/delivery.py", "scripts/lib/app-process.sh"):
            if self.command("git", "hash-object", path) != self.command("git", "rev-parse", f"{target}:{path}"):
                return self.update(pr, last_error=f"deployment tooling differs from main: {path}")
        # Intent is already durable. A dead watcher or busy install lock leaves
        # deployment_pending for the next supervised resume; no background job.
        log = self.state.state_dir / f"delivery-pr-{pr}.log"
        with open(log, "a") as output:
            os.chmod(log, 0o600)
            installer = run_install if self.run is subprocess.run else self.run
            result = installer([str(self.root / "scripts/relaunch.sh"), target], cwd=self.root,
                              env=dict(os.environ, TB_DEPLOY_OWNER=owner, TB_DEPLOY_AUTOMATIC="1"),
                              stdout=output, stderr=subprocess.STDOUT, timeout=1800)
        with self.state.transaction():
            receipt = self.state.read().get("running")
        if result.returncode == 0 and receipt and receipt["sha"] == target and self.receipt_still_running(receipt):
            return self.update(pr, status="running", receipt=receipt, last_error=None, log=str(log))
        reason = log.read_text(errors="replace")[-2000:].strip()
        return self.update(pr, status="deployment_pending" if result.returncode == 75 else "failed",
                           last_error=f"relaunch exit {result.returncode}; {reason or 'verified runtime receipt absent or incomplete'}",
                           log=str(log))

    def processes(self):
        text = self.command("ps", "-axo", "pid=,comm=")
        return {int(parts[0]): parts[1] for line in text.splitlines()
                if len(parts := line.strip().split(None, 1)) == 2 and parts[0].isdigit()}

    def receipt_still_running(self, receipt):
        try:
            return (self.processes().get(receipt["pid"]) == receipt["executable"] and
                    self.command("ps", "-p", str(receipt["pid"]), "-o", "lstart=") == receipt["process_started"] and
                    self.bundle_sha(receipt["bundle"]) == receipt["sha"])
        except (KeyError, OSError, ValueError, subprocess.SubprocessError):
            return False

    @staticmethod
    def bundle_sha(bundle):
        with open(Path(bundle) / "Contents/Info.plist", "rb") as source:
            return plistlib.load(source)["TBSourceCommit"]

    def record_running(self, pid, token, sha, bundle, launched_at):
        with self.state.transaction():
            self.state.require_lock(pid, token)
            state = self.state.read()
            if self.bundle_sha(bundle) != sha:
                raise Blocked("running bundle source stamp differs from deployment target")
            executable = str(Path(bundle) / "Contents/MacOS/TranquilityApp")
            processes = self.processes()
            product = {p: command for p, command in processes.items()
                       if command.endswith(("Tranquility Base.app/Contents/MacOS/TranquilityApp",
                                            "Tranquility Base Dev.app/Contents/MacOS/TranquilityApp"))}
            if len(product) != 1 or executable not in product.values():
                raise Blocked("expected exactly one process from the deployed bundle")
            app_pid = next(iter(product))
            started = self.command("ps", "-p", str(app_pid), "-o", "lstart=")
            if time.mktime(datetime.strptime(started, "%a %b %d %H:%M:%S %Y").timetuple()) < launched_at - 1:
                raise Blocked("the observed process predates this launch")
            receipt = {"sha": sha, "bundle": str(bundle), "executable": executable, "pid": app_pid,
                       "process_started": started, "verified_at": self.now(), "selftests": "passed"}
            state["running"] = receipt
            state["pending"] = [p for p in state["pending"] if p.get("sha") != sha or p.get("channel") != "dev"]
            self.state.write(state)
            return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("watch", "resume"):
        command = sub.add_parser(name)
        command.add_argument("--owner", required=True)
        command.add_argument("--wait", action="store_true", help="poll under supervision; otherwise check once")
        if name == "watch":
            command.add_argument("--pr", required=True, type=int)
            command.add_argument("--observe-only", action="store_true", help="record merge progress without installing (hook mode)")
    sub.add_parser("status")
    record = sub.add_parser("record-running")
    record.add_argument("--pid", type=int, required=True)
    record.add_argument("--lock-token", required=True)
    record.add_argument("--sha", type=state_module.full_sha, required=True)
    record.add_argument("--bundle", type=Path, required=True)
    record.add_argument("--launched-at", type=float, required=True)
    args = parser.parse_args()
    state = state_module.DeploymentState(Path.home() / "Library/Application Support/VoiceDispatch", "/tmp/tb-relaunch.lock")
    delivery = Delivery(state)
    try:
        if args.command == "record-running":
            print(json.dumps(delivery.record_running(args.pid, args.lock_token, args.sha, args.bundle, args.launched_at)))
            return 0
        if args.command == "status":
            with state.transaction():
                status = delivery.read()
            for item in status["requests"].values():
                if item.get("receipt"):
                    item["currently_running"] = delivery.receipt_still_running(item["receipt"])
            print(json.dumps(status, indent=2))
            return 0
        if args.command == "watch" and args.pr < 1:
            parser.error("PR number must be positive")
        while True:
            with state.transaction():
                requests = delivery.read()["requests"]
            targets = [args.pr] if args.command == "watch" else [int(pr) for pr, item in requests.items()
                       if item.get("status") not in ("running", "closed")]
            pending = False
            for pr in targets:
                try:
                    item = (delivery.observe(pr, args.owner) if getattr(args, "observe_only", False)
                            else delivery.step(pr, args.owner))
                except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
                    item = delivery.update(pr, retry_owner=args.owner, last_error=str(error))
                print(json.dumps(item), flush=True)
                pending |= item.get("status") not in ("running", "closed")
            if not args.wait or not pending:
                return 75 if pending else 0
            time.sleep(30)
    except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"delivery pending: {error}", file=sys.stderr)
        return 75
    except KeyboardInterrupt:
        print("Watcher stopped. Pending intent remains; use resume with a named owner.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
