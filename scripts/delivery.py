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

    def candidate(self, pr):
        return json.loads(self.command(
            "gh", "pr", "view", str(pr), "--repo", REPOSITORY, "--json",
            "state,mergeCommit,headRefOid,autoMergeRequest,labels,url,mergedAt,mergeStateStatus,"
            "isDraft,baseRefName,statusCheckRollup"))

    def observe(self, pr, owner):
        # Write BEFORE any network access, so even an interrupted query has an
        # explicit retry owner. Preserve prior merge/runtime evidence on errors.
        previous = self.update(pr, retry_owner=owner)
        if not previous.get("request_owner"):
            previous = self.update(pr, request_owner=owner)
        try:
            observed = self.candidate(pr)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.update(pr, queue_state="unavailable", queue_observation_error=str(error),
                        queue_attention=False, queue_action="Refresh failed; previous merge state is unverified")
            raise
        if observed["state"] != "MERGED":
            labels = {label["name"] for label in observed.get("labels", [])}
            admitted = "merge-queue" in labels
            native = observed.get("autoMergeRequest") is not None
            mode = "competing" if admitted and native else "kodiak" if admitted else "github_auto_merge" if native else "none"
            had_admission = previous.get("queue_first_requested_at") or previous.get("queue_seen_admitted_at")
            conflict = observed.get("mergeStateStatus") == "DIRTY"
            closed = observed["state"] == "CLOSED"
            unknown = observed.get("mergeStateStatus") in (None, "UNKNOWN")
            queue_state = ("closed" if closed else "held" if "queue-hold" in labels
                           else "conflict" if conflict else "unknown" if unknown
                           else "handoff_blocked" if previous.get("queue_handoff_state") == "blocked"
                           else "competing" if admitted and native else "queued" if admitted
                           else "native_auto_merge" if native
                           else "awaiting_readmission" if had_admission and previous.get("queue_conflict_seen_at")
                           else "admission_removed" if had_admission else "not_admitted")
            checks = [c for c in observed.get("statusCheckRollup") or [] if c.get("name") == "Source audit"]
            passed = bool(checks) and all(c.get("status") == "COMPLETED" and c.get("conclusion") == "SUCCESS" for c in checks)
            ready_since = None
            needs_admission = (not closed and not admitted and native and not observed.get("isDraft")
                               and queue_state == "native_auto_merge" and observed.get("mergeStateStatus") == "BEHIND" and passed)
            if needs_admission:
                if previous.get("head_sha") == observed["headRefOid"]:
                    ready_since = previous.get("queue_ready_since")
                if ready_since is None:
                    ready_since = self.now()
                    try:
                        completed = max(datetime.fromisoformat(c["completedAt"].replace("Z", "+00:00")).timestamp() for c in checks)
                        enabled = datetime.fromisoformat(observed["autoMergeRequest"]["enabledAt"].replace("Z", "+00:00")).timestamp()
                        ready_since = min(self.now(), max(completed, enabled))
                    except (KeyError, TypeError, ValueError):
                        pass  # A missing start time uses first observation, never zero.
            attention = queue_state in ("competing", "handoff_blocked", "awaiting_readmission", "admission_removed") or (ready_since is not None and self.now() - ready_since >= 300)
            action = {
                "handoff_blocked": previous.get("queue_admission_error") or "Admission needs its owner",
                "held": "Explicit queue hold; only its owner can release it",
                "conflict": "Resolve and review the conflict, then explicitly re-admit",
                "unknown": "GitHub mergeability is not yet known",
                "competing": "Two merge coordinators are armed; use an owned handoff",
                "native_auto_merge": "GitHub auto-merge is enabled; not admitted to the supervised queue. Use admit --handoff-auto-merge with the reviewed head",
                "awaiting_readmission": "Review the conflict resolution and explicitly re-admit",
                "admission_removed": "Admission was removed; inspect before explicitly re-admitting",
                "not_admitted": "No supervised admission requested",
                "queued": "Supervised admission observed; the bot owns updates and required CI",
                "closed": "Closed without merging",
            }[queue_state]
            return self.update(pr, status="closed" if closed else "queued" if queue_state == "queued" else "awaiting_merge",
                               head_sha=observed["headRefOid"], url=observed["url"], last_error=None,
                               merge_mode=mode, merge_state=observed.get("mergeStateStatus"),
                               source_audit_passed=passed, queue_ready_since=ready_since,
                               queue_attention=attention, queue_action=action, queue_state=queue_state,
                               queue_observation_error=None, queue_observed_at=self.now(),
                               queue_seen_admitted_at=self.now() if admitted else previous.get("queue_seen_admitted_at"),
                               queue_admission_error=None if admitted else previous.get("queue_admission_error"),
                               queue_conflict_seen_at=self.now() if conflict else previous.get("queue_conflict_seen_at"))
        merged = state_module.full_sha(observed["mergeCommit"]["oid"])
        self.update(pr, status="merged", merged_sha=merged, merged_at=observed["mergedAt"],
                    url=observed["url"], last_error=None, queue_state="merged", queue_observed_at=self.now(),
                    queue_admission_error=None, queue_observation_error=None, queue_attention=False,
                    queue_ready_since=None, queue_action=None)
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

    def admit(self, pr, owner, expected_head, handoff_auto_merge=False, resume=False):
        """Authorize one reviewed candidate; durably hand off native auto-merge when requested."""
        if pr < 1 or not owner.strip():
            raise ValueError("a positive PR number and named owner are required")
        expected_head = state_module.full_sha(expected_head)
        self.state.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(self.state.state_dir / "merge-queue-admission.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise Blocked("another operator is admitting a PR; retry after it finishes") from error
            remote = self.command("git", "remote", "get-url", "origin")
            if remote.removesuffix(".git") not in (f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}"):
                raise Blocked("queue admission requires the product repository")
            self.command("git", "fetch", "-q", "origin")
            for path in ("scripts/delivery.py", ".kodiak.toml"):
                if self.command("git", "hash-object", path) != self.command("git", "rev-parse", f"origin/main:{path}"):
                    raise Blocked(f"queue admission tooling differs from merged main: {path}")
            with self.state.transaction():
                previous = self.read()["requests"].get(str(pr), {})
            if resume and (previous.get("queue_owner") != owner or previous.get("queue_requested_head") != expected_head
                           or previous.get("queue_handoff_state") not in ("disable_requested", "admission_pending", "label_requested")):
                raise Blocked("no matching durable admission authorization to resume")
            candidate = self.candidate(pr)
            if resume and candidate.get("state") in ("MERGED", "CLOSED"):
                self.update(pr, queue_handoff_state="complete")
                return self.observe(pr, owner)
            labels = {label["name"] for label in candidate.get("labels", [])}
            # A label request may have succeeded before a timeout or session exit.
            # Once seen, the bot can already have refreshed its head. Do not apply
            # a second label or demand that its updated head equal the old one.
            if resume and previous.get("queue_handoff_state") == "label_requested" and "merge-queue" in labels:
                self.update(pr, queue_handoff_state="complete")
                return self.observe(pr, owner)
            def validate(current):
                if current.get("state") != "OPEN" or current.get("isDraft") is not False or current.get("baseRefName") != "main":
                    raise Blocked("queue admission requires an open, non-draft PR targeting main")
                if current.get("headRefOid") != expected_head:
                    raise Blocked("PR head changed; review its current source before admission")
                if "queue-hold" in {label["name"] for label in current.get("labels", [])}:
                    raise Blocked("queue-hold is present; admission does not release a hold")
                if current.get("mergeStateStatus") in (None, "UNKNOWN", "DIRTY"):
                    raise Blocked("resolve the conflict or wait for GitHub's mergeability result before admission")
            try:
                validate(candidate)
                if resume and previous.get("queue_handoff_state") == "label_requested":
                    raise Blocked("label request outcome is uncertain and admission is absent; inspect before explicitly re-admitting")
                native = candidate.get("autoMergeRequest") is not None
                if native and not handoff_auto_merge:
                    raise Blocked("GitHub auto-merge is already armed; use admit --handoff-auto-merge with the reviewed head")
                self.update(pr, retry_owner=owner, request_owner=previous.get("request_owner") or owner,
                            queue_owner=owner, queue_requested_head=expected_head,
                            queue_first_requested_at=previous.get("queue_first_requested_at", self.now()),
                            queue_last_requested_at=self.now(), queue_admission_error=None,
                            queue_handoff_state="disable_requested" if native else "admission_pending",
                            queue_handoff_authorized=bool(handoff_auto_merge))
                if native:
                    # Persist authorization first. Disabling is idempotent; never
                    # restore native auto-merge after an uncertain outcome.
                    self.command("gh", "pr", "merge", str(pr), "--repo", REPOSITORY, "--disable-auto")
                candidate = self.candidate(pr)
                if candidate.get("state") in ("MERGED", "CLOSED"):
                    self.update(pr, queue_handoff_state="complete")
                    return self.observe(pr, owner)
                validate(candidate)
                if candidate.get("autoMergeRequest") is not None:
                    raise Blocked("GitHub auto-merge is still armed; no queue label was added")
                self.update(pr, queue_handoff_state="admission_pending")
                if "merge-queue" not in {label["name"] for label in candidate.get("labels", [])}:
                    self.update(pr, queue_handoff_state="label_requested")
                    self.command("gh", "pr", "edit", str(pr), "--repo", REPOSITORY, "--add-label", "merge-queue")
                self.update(pr, queue_handoff_state="complete")
                return self.observe(pr, owner)
            except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
                # Invalid initial requests create no authorization. A stopped or
                # uncertain mutation retains its intent and original reviewed head.
                if str(pr) in self.read()["requests"]:
                    fields = {"queue_admission_error": str(error)}
                    if isinstance(error, Blocked):
                        fields.update(queue_handoff_state="blocked", queue_action=str(error), queue_attention=True)
                    self.update(pr, **fields)
                raise

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
        candidates, errors, waiting, attention = [], [], [], []
        for request in requests:
            if request.get("status") in ("running", "closed"):
                continue
            pr = int(request["pr"])
            try:
                if request.get("queue_handoff_state") in ("disable_requested", "admission_pending", "label_requested"):
                    self.admit(pr, request["queue_owner"], request["queue_requested_head"],
                               handoff_auto_merge=request.get("queue_handoff_authorized", False), resume=True)
                item = self.observe(pr, "desktop-delivery-supervisor")
                if item["status"] == "deployment_pending": candidates.append(item)
                elif item["status"] != "closed": waiting.append(pr)
                if item.get("queue_attention"): attention.append(pr)
            except (Blocked, OSError, ValueError, subprocess.SubprocessError) as error:
                self.update(pr, retry_owner="desktop-delivery-supervisor", last_error=str(error))
                errors.append(pr)
        if not candidates:
            return save(phase="unavailable" if errors else "attention" if attention else "awaiting_merge" if waiting else "idle",
                        target_sha=None, attention_prs=attention,
                        reason="Observation or admission needs attention; intent retained" if errors else
                        f"Merge admission needs attention: {', '.join('#' + str(pr) for pr in attention)}" if attention else
                        "Recorded requests are waiting for protected merge" if waiting else None)
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
    admit = sub.add_parser("admit", help="record delivery intent, then request protected queue admission")
    admit.add_argument("--pr", type=int, required=True)
    admit.add_argument("--owner", required=True)
    admit.add_argument("--head", type=state_module.full_sha, required=True, help="reviewed full PR head SHA")
    admit.add_argument("--handoff-auto-merge", action="store_true",
                       help="authorize disabling native auto-merge before supervised admission of this reviewed head")
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
        if args.command == "admit":
            item = delivery.admit(args.pr, args.owner, args.head, handoff_auto_merge=args.handoff_auto_merge)
            print(json.dumps(item))
            return 0 if item.get("status") in ("queued", "deployment_pending", "running") else 75
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
                if item.get("status") not in ("running", "closed") and (not item.get("queue_observed_at") or time.time() - item["queue_observed_at"] > 300):
                    item.update(queue_state="stale", queue_action="No fresh merge observation; progress unverified")
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
