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


def signal_install_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin can reject a cleanup signal after TERM has removed all live
        # members. Do not mask EPERM on a surviving process: verify the group.
        rows = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True, timeout=5)
        for row in rows.splitlines():
            fields = row.split()
            if len(fields) >= 2 and fields[0] == str(pgid) and not fields[1].startswith("Z"):
                raise


def run_install(command, **kwargs):
    """Stop the whole build/install process group on timeout or interruption."""
    timeout = kwargs.pop("timeout")
    with subprocess.Popen(command, start_new_session=True, **kwargs) as child:
        try:
            return subprocess.CompletedProcess(command, child.wait(timeout=timeout))
        except BaseException:
            try:
                signal_install_group(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
            finally:
                try:
                    signal_install_group(child.pid, signal.SIGKILL)
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

    def step(self, pr, owner, blocked_targets=()):
        self.state.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(self.state.state_dir / f"delivery-pr-{pr}.lock", "a") as lock:
            os.chmod(lock.name, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise Blocked(f"another watcher is checking PR {pr}; its intent remains recorded") from error
            return self._step(pr, owner, blocked_targets)

    def _step(self, pr, owner, blocked_targets=()):
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
        if target in blocked_targets:
            return self.update(pr, status="failed", last_error="automatic retry held for this source; inspect the failure and retry explicitly")
        # A current checkout is necessary: relaunch and its shared helpers are
        # the policy. Never build a new app with an old deployment driver.
        for path in ("scripts/relaunch.sh", "scripts/build-clean.sh", "scripts/lib/deployment.sh",
                     "scripts/deployment-state.py", "scripts/delivery.py", "scripts/lib/app-process.sh",
                     "scripts/prepare-dev.py", "scripts/run-stage.py"):
            if self.command("git", "hash-object", path) != self.command("git", "rev-parse", f"{target}:{path}"):
                return self.update(pr, last_error=f"deployment tooling differs from main: {path}")
        # Intent is already durable. A dead watcher or busy install lock leaves
        # deployment_pending for the next foreground or installed worker tick.
        log = self.state.state_dir / f"delivery-pr-{pr}.log"
        with open(log, "a") as output:
            os.chmod(log, 0o600)
            attempt_start = output.tell()
            installer = run_install if self.run is subprocess.run else self.run
            result = installer([str(self.root / "scripts/relaunch.sh"), target], cwd=self.root,
                              env=dict(os.environ, TB_DEPLOY_OWNER=owner, TB_DEPLOY_AUTOMATIC="1"),
                              stdout=output, stderr=subprocess.STDOUT, timeout=1800)
        with self.state.transaction():
            receipt = self.state.read().get("running")
        if result.returncode == 0 and receipt and receipt["sha"] == target and self.receipt_still_running(receipt):
            return self.update(pr, status="running", receipt=receipt, last_error=None, log=str(log))
        with log.open("rb") as recorded:
            recorded.seek(attempt_start)
            reason = recorded.read().decode("utf-8", errors="replace")[-2000:].strip()
        if result.returncode == 75:
            # The product needs the actual blocker, not build/signing output
            # that can truncate the blocker out of its bounded status payload.
            lines = [line.strip() for line in reason.splitlines()]
            explicit = next((line for line in reversed(lines) if line.startswith("deployment deferred: ")), None)
            detail = explicit.removeprefix("deployment deferred: ").split("; deployment pending", 1)[0] if explicit else None
            return self.update(pr, status="deployment_pending", log=str(log),
                               last_error=detail or "Activation deferred; see the delivery log")
        return self.update(pr, status="deployment_pending" if result.returncode == 75 else "failed",
                           last_error=f"relaunch exit {result.returncode}; {reason or 'verified runtime receipt absent or incomplete'}",
                           log=str(log))

    def supervise(self):
        """One durable worker tick. Only recorded PR delivery intent is eligible."""
        self.state.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(self.state.state_dir / "delivery-supervisor.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"phase": "busy"}
            return self._supervise()

    def _supervise(self):
        path = self.state.state_dir / "delivery-supervisor.json"
        previous = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(previous, dict):
            raise Blocked("invalid supervisor state")
        def save(**fields):
            previous.update(fields, checked_at=self.now(), owner="desktop-delivery-supervisor")
            fd, temporary = tempfile.mkstemp(prefix=".supervisor-", dir=self.state.state_dir)
            try:
                with os.fdopen(fd, "w") as out:
                    json.dump(previous, out); out.flush(); os.fsync(out.fileno())
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
            return dict(previous)

        # A crashed tick may have reached activation. Permit one recovery attempt,
        # then hold that target. A completed failed activation is held immediately.
        interrupted_target = previous.get("attempt_target") if previous.get("phase") == "activating" else None
        blocked = {previous.get("failed_target")}
        if interrupted_target and previous.get("attempts", 0) >= 2:
            blocked.add(interrupted_target)
        with self.state.transaction():
            requests = list(self.read()["requests"].values())
        blocked.update(r.get("target_sha") for r in requests if r.get("status") == "failed")
        blocked.discard(None)
        save(phase="checking", reason=None)
        candidates, errors = [], []
        for request in requests:
            if request.get("status") in ("running", "closed"):
                continue
            pr = int(request["pr"])
            try:
                item = self.observe(pr, "desktop-delivery-supervisor")
                if item["status"] == "deployment_pending": candidates.append(item)
            except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
                self.update(pr, retry_owner="desktop-delivery-supervisor", last_error=str(error))
                errors.append(pr)
        if not candidates:
            return save(phase="unavailable" if errors else "idle", target_sha=None,
                        reason="GitHub observation failed; delivery intent retained" if errors else None)
        # Observe chooses current main, containing the requested merge. One tick
        # starts at most one install, however many PRs are waiting.
        item = candidates[-1]
        target = item["target_sha"]
        attempts = previous.get("attempts", 0) if previous.get("attempt_target") == target else 0
        save(phase="activating", target_sha=target, attempt_target=target, attempts=attempts + 1)
        try:
            result = self.step(item["pr"], "desktop-delivery-supervisor", blocked_targets=blocked)
        except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
            self.update(item["pr"], retry_owner="desktop-delivery-supervisor", last_error=str(error))
            # Interrupted installers leave an uncertain outcome, so the same
            # crash budget also applies to a timeout. Network failures retry.
            return save(phase="activating" if isinstance(error, subprocess.TimeoutExpired) else "unavailable",
                        reason="Delivery did not complete; intent retained")
        if result["status"] == "running":
            receipt = result["receipt"]
            for other in candidates:
                if other["pr"] == item["pr"]: continue
                try:
                    self.command("git", "merge-base", "--is-ancestor", other["merged_sha"], receipt["sha"])
                except subprocess.SubprocessError:
                    continue
                self.update(other["pr"], status="running", target_sha=receipt["sha"], receipt=receipt, last_error=None)
            return save(phase="running", target_sha=receipt["sha"], attempts=0, failed_target=None, reason=None)
        failed = result["status"] == "failed"
        target = result.get("target_sha", target)
        return save(phase="failed" if failed else "deferred", target_sha=target, attempts=0,
                    failed_target=target if failed else previous.get("failed_target"),
                    reason="Activation failed; automatic retry held for this source" if failed else result.get("last_error"))

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
    sub.add_parser("supervise", help="one coalescing tick for the installed background worker")
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
        if args.command == "supervise":
            print(json.dumps(delivery.supervise()))
            return 0
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
                if item.get("status") == "failed":
                    return 1
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
