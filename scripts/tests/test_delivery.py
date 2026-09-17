#!/usr/bin/env python3
"""Delivery evidence tests; remote, app processes and installs are fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("delivery", Path(__file__).resolve().parents[1] / "delivery.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
A, B = "a" * 40, "b" * 40


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tb-delivery-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = module.state_module.DeploymentState(self.root / "state", self.root / "lock")
        self.delivery = module.Delivery(self.state, self.root, self.run_command)
        self.observed = {"state": "OPEN", "headRefOid": A, "autoMergeRequest": None,
                         "labels": [], "url": "https://example.invalid/pr/1", "mergedAt": None}
        self.app = self.root / "Tranquility Base Dev.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"TBSourceCommit": B}))
        self.executable = str(self.app / "Contents/MacOS/TranquilityApp")
        self.started = "Tue Sep 15 16:00:00 2026"
        self.epoch = time.mktime(time.strptime(self.started, "%a %b %d %H:%M:%S %Y"))
        self.processes = f"42 {self.executable}"
        self.returncode = 75
        self.install_count = 0
        self.stale_driver = False
        self.ancestry_failure = False
        self.network_failure = False
        self.interrupt_install = False
        self.make_receipt = False
        self.main_sha = B
        self.not_ancestor = None

    def run_command(self, args, **kwargs):
        output = ""
        if args[0] == "gh":
            if self.network_failure:
                raise subprocess.TimeoutExpired(args, 45)
            output = json.dumps(self.observed)
        elif args[:4] == ["git", "remote", "get-url", "origin"]:
            output = f"https://github.com/{module.REPOSITORY}.git"
        elif args[:2] == ["git", "merge-base"]:
            if self.ancestry_failure or tuple(args[-2:]) == self.not_ancestor:
                raise subprocess.CalledProcessError(1, args)
        elif args[:2] == ["git", "hash-object"]:
            output = "old" if self.stale_driver else "blob"
        elif args[:2] == ["git", "rev-parse"]:
            output = self.main_sha if args[-1] == "origin/main" else "blob"
        elif args[:2] == ["ps", "-axo"]:
            output = self.processes
        elif args[0] == "ps":
            output = self.started
        elif args[0].endswith("relaunch.sh"):
            self.install_count += 1
            self.assertEqual(args[-1], self.main_sha)
            self.assertEqual(kwargs["env"]["TB_DEPLOY_AUTOMATIC"], "1")
            if self.interrupt_install:
                raise KeyboardInterrupt
            if self.make_receipt:
                self.record()
            return subprocess.CompletedProcess(args, self.returncode)
        return subprocess.CompletedProcess(args, 0, output)

    def merge(self):
        self.observed.update(state="MERGED", mergeCommit={"oid": A}, mergedAt="2026-09-15T23:00:00Z")

    def record(self):
        token = self.state.acquire(os.getpid())
        try:
            return self.delivery.record_running(os.getpid(), token, B, self.app, self.epoch)
        finally:
            self.state.unlock(os.getpid(), token)

    def test_open_pr_is_not_called_queued_without_admission(self):
        self.assertEqual(self.delivery.step(1, "owner")["status"], "awaiting_merge")
        self.assertEqual(self.install_count, 0)

    def test_queue_admission_is_not_a_merge_or_install(self):
        for admission in ({"autoMergeRequest": {}}, {"labels": [{"name": "merge-queue"}]}):
            self.observed.update(admission)
            if "autoMergeRequest" in admission:
                self.observed["autoMergeRequest"] = {"enabledAt": "now"}
            self.assertEqual(self.delivery.step(1, "owner")["status"], "queued")
        self.assertEqual(self.install_count, 0)

    def test_actual_squash_sha_and_coalesced_target_are_both_retained(self):
        self.merge()
        item = self.delivery.step(1, "owner")
        self.assertEqual((item["merged_sha"], item["target_sha"], item["status"]), (A, B, "deployment_pending"))
        self.assertEqual(self.install_count, 1)

    def test_crashed_watcher_leaves_pending_intent_and_owner(self):
        self.merge()
        self.interrupt_install = True
        with self.assertRaises(KeyboardInterrupt):
            self.delivery.step(1, "owner")
        reopened = module.Delivery(self.state)
        item = reopened.read()["requests"]["1"]
        self.assertEqual((item["status"], item["target_sha"], item["retry_owner"]), ("deployment_pending", B, "owner"))

    def test_network_failure_still_has_a_durable_retry_owner(self):
        self.network_failure = True
        with self.assertRaises(subprocess.TimeoutExpired):
            self.delivery.step(1, "owner")
        self.assertEqual(self.delivery.read()["requests"]["1"]["retry_owner"], "owner")

    def test_merge_outside_main_cannot_be_deployed(self):
        self.merge()
        self.ancestry_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.delivery.step(1, "owner")
        self.assertEqual(self.install_count, 0)

    def test_stale_helpers_defer_before_installation(self):
        self.merge()
        self.stale_driver = True
        self.assertEqual(self.delivery.step(1, "owner")["status"], "deployment_pending")
        self.assertEqual(self.install_count, 0)

    def test_zero_exit_without_runtime_receipt_is_not_running(self):
        self.merge()
        self.returncode = 0
        self.assertEqual(self.delivery.step(1, "owner")["status"], "failed")

    def test_verified_runtime_is_acknowledged_and_retry_is_idempotent(self):
        self.merge()
        self.returncode = 0
        self.make_receipt = True
        self.assertEqual(self.delivery.step(1, "owner")["status"], "running")
        self.assertEqual(self.delivery.step(1, "owner")["status"], "running")
        self.assertEqual(self.install_count, 1)

    def test_old_process_with_replaced_bundle_is_not_a_new_deploy(self):
        token = self.state.acquire(os.getpid())
        with self.assertRaisesRegex(module.Blocked, "predates"):
            self.delivery.record_running(os.getpid(), token, B, self.app, self.epoch + 20)

    def test_later_main_does_not_redeploy_an_already_delivered_merge(self):
        self.merge()
        self.returncode = 0
        self.make_receipt = True
        self.assertEqual(self.delivery.step(1, "owner")["status"], "running")
        self.main_sha = "c" * 40
        result = self.delivery.step(1, "owner")
        self.assertEqual(result["status"], "running")
        self.assertEqual(result["target_sha"], B)
        self.assertEqual(self.install_count, 1)

    def test_receipt_must_contain_the_requested_merge_and_be_on_main(self):
        self.merge()
        self.record()
        self.main_sha = "c" * 40
        for pair in ((A, B), (B, "origin/main")):
            with self.subTest(pair=pair):
                self.not_ancestor = pair
                result = self.delivery.step(1, "owner")
                self.assertEqual(result["status"], "deployment_pending")
        self.assertEqual(self.install_count, 2)

    def test_wrong_full_stamp_or_second_process_blocks_receipt(self):
        token = self.state.acquire(os.getpid())
        with self.assertRaisesRegex(module.Blocked, "stamp"):
            self.delivery.record_running(os.getpid(), token, A, self.app, self.epoch)
        self.processes += "\n43 /Applications/Tranquility Base.app/Contents/MacOS/TranquilityApp"
        with self.assertRaisesRegex(module.Blocked, "exactly one"):
            self.delivery.record_running(os.getpid(), token, B, self.app, self.epoch)

    def test_reused_pid_invalidates_an_old_receipt(self):
        receipt = self.record()
        self.started = "Tue Sep 15 16:01:00 2026"
        self.assertFalse(self.delivery.receipt_still_running(receipt))

    def test_completion_clears_only_the_verified_target(self):
        token = self.state.acquire(os.getpid())
        self.state.reserve(os.getpid(), token, "preview", A, "dev", 120)
        for sha in (B, "c" * 40):
            with self.assertRaises(module.Blocked):
                self.state.authorize(os.getpid(), token, "relaunch", sha, "dev", "owner")
        self.state.unlock(os.getpid(), token)
        self.record()
        self.assertEqual([p["sha"] for p in self.state.read()["pending"]], ["c" * 40])

    def test_capture_wait_rechecks_activation_before_stopping(self):
        helper = module.ROOT / "scripts/lib/app-process.sh"
        result = subprocess.run(["bash", "-c", '''set -euo pipefail
. "$1"
app_running() { return 0; }
wait_for_microphone() { echo "capture finished"; }
tb_before_app_stop() { echo "activation deferred after capture"; exit 75; }
pkill() { echo "unexpected kill"; exit 99; }
app_stop
''', "fixture", str(helper)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["capture finished", "activation deferred after capture"])

    def test_long_capture_defers_automatic_delivery_without_stopping_the_app(self):
        marker = self.root / "capturing"
        marker.write_text(str(int(time.time())))
        for automatic, expected in (("1", 75), ("0", 1)):
            with self.subTest(automatic=automatic):
                result = subprocess.run(["bash", "-c", '''set -euo pipefail
. "$1"
TB_CAPTURE_MARKER="$2"
TB_MIC_GIVE_UP_AFTER=0
TB_DEPLOY_AUTOMATIC="$3"
app_running() { return 0; }
pkill() { echo "unexpected stop"; exit 99; }
app_stop
''', "fixture", str(module.ROOT / "scripts/lib/app-process.sh"), str(marker), automatic],
                    text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertNotIn("unexpected stop", result.stdout)
                self.assertTrue(marker.exists())

    def test_timeout_stops_install_children(self):
        marker = self.root / "child-pid"
        program = '''import subprocess, sys, time
from pathlib import Path
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
Path(sys.argv[1]).write_text(str(child.pid))
time.sleep(30)
'''
        with self.assertRaises(subprocess.TimeoutExpired):
            module.run_install([sys.executable, "-c", program, str(marker)],
                               timeout=0.5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertTrue(marker.exists())
        status = subprocess.run(["ps", "-p", marker.read_text(), "-o", "stat="], text=True, capture_output=True).stdout.strip()
        self.assertTrue(not status or status.startswith("Z"), f"install child still running: {status}")


    def test_supervisor_restarts_and_coalesces_recorded_requests(self):
        self.merge()
        for pr in (1, 2, 3): self.delivery.update(pr, status="requested")
        self.returncode, self.make_receipt = 0, True
        reopened = module.Delivery(self.state, self.root, self.run_command)
        self.assertEqual(reopened.supervise()["phase"], "running")
        self.assertEqual(self.install_count, 1)
        self.assertTrue(all(r["status"] == "running" for r in reopened.read()["requests"].values()))
        self.assertEqual(reopened.supervise()["phase"], "idle")
        self.assertEqual(self.install_count, 1)

    def test_supervisor_preserves_preview_then_resumes_after_release(self):
        self.merge(); self.delivery.update(1, status="requested")
        token = self.state.acquire(os.getpid())
        reservation = self.state.reserve(os.getpid(), token, "preview-owner", A, "dev", 20)
        self.state.unlock(os.getpid(), token)
        self.assertEqual(self.delivery.supervise()["phase"], "deferred")
        self.assertEqual(self.install_count, 1)  # preparation/activation attempt defers safely
        token = self.state.acquire(os.getpid())
        self.state.release(os.getpid(), token, reservation)
        self.state.unlock(os.getpid(), token)
        self.returncode, self.make_receipt = 0, True
        self.assertEqual(self.delivery.supervise()["phase"], "running")
        self.assertEqual(self.install_count, 2)

    def test_supervisor_holds_failed_source_across_restart_and_other_requests(self):
        self.merge(); self.delivery.update(1, status="requested"); self.returncode = 1
        self.assertEqual(self.delivery.supervise()["phase"], "failed")
        self.delivery.update(2, status="requested")
        reopened = module.Delivery(self.state, self.root, self.run_command)
        self.assertEqual(reopened.supervise()["phase"], "failed")
        self.assertEqual(self.install_count, 1)
        self.main_sha = "c" * 40
        reopened.supervise()
        self.assertEqual(self.install_count, 2)

    def test_supervisor_retains_network_failure_and_recovers(self):
        self.delivery.update(1, status="requested"); self.network_failure = True
        self.assertEqual(self.delivery.supervise()["phase"], "unavailable")
        self.assertEqual(self.install_count, 0)
        self.network_failure = False; self.merge()
        self.returncode, self.make_receipt = 0, True
        self.assertEqual(self.delivery.supervise()["phase"], "running")

    def test_supervisor_limits_interrupted_activation_recovery(self):
        self.merge(); self.delivery.update(1, status="requested"); self.interrupt_install = True
        for _ in range(2):
            with self.assertRaises(KeyboardInterrupt): self.delivery.supervise()
        self.assertEqual(self.delivery.supervise()["phase"], "failed")
        self.assertEqual(self.install_count, 2)

    def test_safe_activation_deferral_does_not_exhaust_retry_budget(self):
        self.merge(); self.delivery.update(1, status="requested"); self.returncode = 75
        for _ in range(3): self.assertEqual(self.delivery.supervise()["phase"], "deferred")
        self.returncode, self.make_receipt = 0, True
        self.assertEqual(self.delivery.supervise()["phase"], "running")

    def test_supervisor_never_replays_historical_preview_refusals(self):
        token = self.state.acquire(os.getpid())
        self.state.reserve(os.getpid(), token, "preview", A, "dev", 20)
        with self.assertRaises(module.Blocked):
            self.state.authorize(os.getpid(), token, "relaunch", B, "dev", "old-owner")
        self.state.unlock(os.getpid(), token)
        self.assertEqual(self.delivery.supervise()["phase"], "idle")
        self.assertEqual(self.install_count, 0)

    def test_foreground_wait_stops_after_failed_activation(self):
        from unittest.mock import patch
        self.merge(); self.returncode = 1
        with patch.object(module, "Delivery", return_value=self.delivery), \
             patch.object(module.state_module, "DeploymentState", return_value=self.state), \
             patch.object(sys, "argv", ["delivery.py", "watch", "--pr", "1", "--owner", "operator", "--wait"]), \
             patch.object(module.time, "sleep") as sleep:
            self.assertEqual(module.main(), 1)
        self.assertEqual(self.install_count, 1)
        sleep.assert_not_called()

    def test_cleanup_permission_error_requires_proof_no_group_members_are_live(self):
        from unittest.mock import patch
        for rows in ("", "123 Z\n999 S\n"):
            with patch.object(module.os, "killpg", side_effect=PermissionError(1, "not permitted")), \
                 patch.object(module.subprocess, "check_output", return_value=rows):
                module.signal_install_group(123, module.signal.SIGKILL)
        with patch.object(module.os, "killpg", side_effect=PermissionError(1, "not permitted")), \
             patch.object(module.subprocess, "check_output", return_value="123 S\n"):
            with self.assertRaises(PermissionError): module.signal_install_group(123, module.signal.SIGKILL)

    def test_cleanup_permission_error_cannot_pass_when_process_inspection_fails(self):
        from unittest.mock import patch
        with patch.object(module.os, "killpg", side_effect=PermissionError(1, "not permitted")), \
             patch.object(module.subprocess, "check_output", side_effect=subprocess.TimeoutExpired("ps", 5)):
            with self.assertRaises(subprocess.TimeoutExpired): module.signal_install_group(123, module.signal.SIGKILL)


class HookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("merge_hook", module.ROOT / "scripts/hooks/merge-delivery.py")
        cls.hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.hook)

    def test_literal_pr_and_repo_options(self):
        self.assertEqual(self.hook.merge_target("git status && gh pr merge 42 --auto --squash --repo robertnowell/tranquility-base"),
                         (True, "42", module.REPOSITORY))
        self.assertEqual(self.hook.resolve_pr("42", module.REPOSITORY, "/unused"), 42)
        self.assertEqual(self.hook.resolve_pr("https://github.com/robertnowell/tranquility-base/pull/42", None, "/unused"), 42)

    def test_other_repo_and_dynamic_shell_are_not_deployed(self):
        self.assertIsNone(self.hook.resolve_pr("42", "other/repo", "/unused"))
        with self.assertRaises(ValueError):
            self.hook.resolve_pr("$PR", module.REPOSITORY, "/unused")
        self.assertEqual(self.hook.merge_target("echo 'gh pr merge 42'"), (False, None, None))

    def test_body_text_is_not_mistaken_for_target(self):
        self.assertEqual(self.hook.merge_target("gh pr merge 42 --squash --body 'a change for 99'"), (True, "42", None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
