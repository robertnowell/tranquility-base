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
                         "labels": [], "url": "https://example.invalid/pr/1", "mergedAt": None,
                         "isDraft": False, "baseRefName": "main", "mergeStateStatus": "CLEAN"}
        self.disable_calls = 0
        self.disable_timeout = False
        self.disable_applied = True
        self.change_during_disable = None
        self.remove_label_on_timeout = False
        self.admission_calls = 0
        self.admission_timeout = False
        self.merge_during_admission = False
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
        self.install_output = ""
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
            if args[:3] == ["gh", "pr", "merge"]:
                self.assertIn("--disable-auto", args)
                saved = self.delivery.read()["requests"][args[3]]
                self.assertEqual(saved["queue_handoff_state"], "disable_requested")
                self.assertEqual(saved["queue_requested_head"], A)
                self.assertTrue(saved["queue_handoff_authorized"])
                self.disable_calls += 1
                if self.disable_applied: self.observed["autoMergeRequest"] = None
                if self.change_during_disable: self.observed.update(self.change_during_disable)
                if self.disable_timeout: raise subprocess.TimeoutExpired(args, 45)
            if args[:3] == ["gh", "pr", "edit"]:
                # Inspect disk from a fresh instance at the mutation boundary.
                saved = module.Delivery(self.state).read()["requests"][args[3]]
                self.assertEqual(saved["queue_requested_head"], A)
                self.assertTrue(saved["queue_owner"])
                self.admission_calls += 1
                self.observed["labels"] = [{"name": "merge-queue"}]
                if self.merge_during_admission:
                    self.merge()
                if self.admission_timeout:
                    if self.remove_label_on_timeout: self.observed["labels"] = []
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
            kwargs["stdout"].write(self.install_output)
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

    def test_native_auto_merge_is_not_supervised_admission(self):
        self.observed["autoMergeRequest"] = {"enabledAt": "now"}
        item = self.delivery.step(1, "owner")
        self.assertEqual(item["status"], "awaiting_merge")
        self.assertEqual(item["queue_state"], "native_auto_merge")
        self.assertEqual(item["merge_mode"], "github_auto_merge")
        self.assertIsNone(item["queue_seen_admitted_at"])
        self.assertEqual(self.install_count, 0)
        self.assertEqual(self.admission_calls, 0)

    def test_queue_admission_is_not_a_merge_or_install(self):
        self.observed["labels"] = [{"name": "merge-queue"}]
        item = self.delivery.step(1, "owner")
        self.assertEqual(item["status"], "queued")
        self.assertEqual(item["merge_mode"], "kodiak")
        self.assertEqual(self.install_count, 0)

    def test_two_coordinators_never_look_normally_queued(self):
        self.observed.update(autoMergeRequest={}, labels=[{"name": "merge-queue"}])
        item = self.delivery.observe(1, "owner")
        self.assertEqual(item["queue_state"], "competing")
        self.assertTrue(item["queue_attention"])
        self.observed["labels"].append({"name": "queue-hold"})
        self.assertEqual(self.delivery.observe(1, "owner")["queue_state"], "held")

    def test_native_behind_stall_has_real_green_start_and_stable_owner(self):
        self.delivery.now = lambda: 1000
        self.observed.update(mergeStateStatus="BEHIND", autoMergeRequest={"enabledAt": "1970-01-01T00:10:00Z"},
                             statusCheckRollup=[{"name": "Source audit", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "1970-01-01T00:11:00Z"}])
        self.delivery.observe(1, "author")
        self.assertEqual(self.delivery.supervise()["phase"], "attention")
        item = self.delivery.read()["requests"]["1"]
        self.assertEqual(item["queue_ready_since"], 660)
        self.assertEqual(item["request_owner"], "author")
        self.assertEqual(self.disable_calls + self.admission_calls, 0)
        self.observed["statusCheckRollup"][0].update(status="IN_PROGRESS", conclusion="")
        item = self.delivery.observe(1, "worker")
        self.assertIsNone(item["queue_ready_since"])
        self.assertFalse(item["queue_attention"])

    def test_unobserved_check_start_waits_five_minutes_and_head_change_resets(self):
        now = [1000]; self.delivery.now = lambda: now[0]
        self.observed.update(mergeStateStatus="BEHIND", autoMergeRequest={}, statusCheckRollup=[
            {"name": "Source audit", "status": "COMPLETED", "conclusion": "SUCCESS"}])
        self.assertFalse(self.delivery.observe(1, "owner")["queue_attention"])
        now[0] = 1300
        self.assertTrue(self.delivery.observe(1, "owner")["queue_attention"])
        self.observed["headRefOid"] = B
        self.assertFalse(self.delivery.observe(1, "owner")["queue_attention"])

    def test_failed_refresh_retains_evidence_but_marks_it_unavailable(self):
        self.observed["labels"] = [{"name": "merge-queue"}]
        old = self.delivery.observe(1, "author")
        self.network_failure = True
        with self.assertRaises(subprocess.TimeoutExpired): self.delivery.observe(1, "worker")
        item = self.delivery.read()["requests"]["1"]
        self.assertEqual(item["queue_state"], "unavailable")
        self.assertEqual(item["queue_observed_at"], old["queue_observed_at"])
        self.assertTrue(item["queue_observation_error"])

    def test_authorized_handoff_disables_before_enrolling(self):
        self.observed["autoMergeRequest"] = {}
        item = self.delivery.admit(1, "author", A, handoff_auto_merge=True)
        self.assertEqual((self.disable_calls, self.admission_calls, self.install_count), (1, 1, 0))
        self.assertEqual(item["queue_state"], "queued")
        self.assertEqual(item["queue_handoff_state"], "complete")

    def test_interrupted_handoff_resumes_only_the_recorded_head_after_session_exit(self):
        self.observed["autoMergeRequest"] = {}; self.disable_timeout = True
        with self.assertRaises(subprocess.TimeoutExpired): self.delivery.admit(1, "author", A, handoff_auto_merge=True)
        self.assertEqual(self.admission_calls, 0)
        self.disable_timeout = False
        reopened = module.Delivery(self.state, self.root, self.run_command)
        self.assertEqual(reopened.supervise()["phase"], "awaiting_merge")
        self.assertEqual(self.admission_calls, 1)
        self.assertEqual(reopened.read()["requests"]["1"]["queue_owner"], "author")
        self.merge(); self.returncode, self.make_receipt = 0, True
        self.assertEqual(reopened.supervise()["phase"], "running")

    def test_handoff_refuses_changed_head_hold_and_rearmed_auto_merge(self):
        for change in ({"headRefOid": B}, {"labels": [{"name": "queue-hold"}]},
                       {"autoMergeRequest": {}}, {"mergeStateStatus": "DIRTY"}):
            with self.subTest(change=change):
                self.observed.update(headRefOid=A, labels=[], autoMergeRequest={}, mergeStateStatus="CLEAN")
                self.change_during_disable = change
                with self.assertRaises(module.Blocked): self.delivery.admit(1, "author", A, handoff_auto_merge=True)
                self.assertEqual(self.admission_calls, 0)
                self.assertEqual(self.delivery.read()["requests"]["1"]["queue_handoff_state"], "blocked")

    def test_resume_refuses_a_new_head_without_new_review(self):
        self.observed["autoMergeRequest"] = {}; self.disable_timeout = True
        with self.assertRaises(subprocess.TimeoutExpired): self.delivery.admit(1, "author", A, handoff_auto_merge=True)
        self.observed["headRefOid"] = B; self.disable_timeout = False
        self.assertEqual(self.delivery.supervise()["phase"], "unavailable")
        self.assertEqual(self.admission_calls, 0)
        self.assertEqual(self.delivery.supervise()["phase"], "attention")

    def test_unknown_label_outcome_is_observed_not_blindly_reapplied(self):
        self.admission_timeout = True
        with self.assertRaises(subprocess.TimeoutExpired): self.delivery.admit(1, "author", A)
        self.observed["headRefOid"] = B  # bot already updated the admitted candidate
        self.admission_timeout = False
        self.assertEqual(self.delivery.supervise()["phase"], "awaiting_merge")
        self.assertEqual(self.admission_calls, 1)
        self.observed["labels"] = []  # later withdrawal must not be undone
        self.delivery.supervise()
        self.assertEqual(self.admission_calls, 1)
        self.assertEqual(self.delivery.read()["requests"]["1"]["queue_state"], "admission_removed")

    def test_unknown_absent_label_needs_owner_instead_of_reapplying_withdrawal(self):
        self.admission_timeout = self.remove_label_on_timeout = True
        with self.assertRaises(subprocess.TimeoutExpired): self.delivery.admit(1, "author", A)
        self.admission_timeout = False
        self.assertEqual(self.delivery.supervise()["phase"], "unavailable")
        self.assertEqual(self.admission_calls, 1)
        self.assertEqual(self.delivery.read()["requests"]["1"]["queue_handoff_state"], "blocked")

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

    def test_admission_records_intent_before_label_and_never_installs(self):
        result = self.delivery.admit(1, "coordinator", A)
        self.assertEqual(result["status"], "queued")
        self.assertEqual(result["queue_owner"], "coordinator")
        self.assertEqual(result["queue_requested_head"], A)
        self.assertEqual(self.admission_calls, 1)
        self.assertEqual(self.install_count, 0)

    def test_admission_refuses_wrong_source_drafts_holds_and_competing_merges(self):
        for change in ({"headRefOid": B}, {"isDraft": True}, {"baseRefName": "release"},
                       {"state": "MERGED"}, {"state": "CLOSED"}, {"autoMergeRequest": {}},
                       {"labels": [{"name": "queue-hold"}]}, {"mergeStateStatus": "DIRTY"},
                       {"mergeStateStatus": "UNKNOWN"}):
            with self.subTest(change=change):
                original = dict(self.observed)
                self.observed.update(change)
                with self.assertRaises(module.Blocked):
                    self.delivery.admit(1, "coordinator", A)
                self.observed = original
        self.assertEqual(self.admission_calls, 0)
        self.assertFalse(self.delivery.read()["requests"])

    def test_admission_refuses_unmerged_driver_and_invalid_arguments(self):
        self.stale_driver = True
        with self.assertRaisesRegex(module.Blocked, "tooling differs"):
            self.delivery.admit(1, "coordinator", A)
        for pr, owner, sha in ((0, "owner", A), (1, " ", A), (1, "owner", "short")):
            with self.subTest(pr=pr, owner=owner, sha=sha), self.assertRaises((ValueError, module.argparse.ArgumentTypeError)):
                self.delivery.admit(pr, owner, sha)
        self.assertEqual(self.admission_calls, 0)

    def test_failed_intent_write_never_applies_the_label(self):
        from unittest.mock import patch
        with patch.object(self.delivery, "update", side_effect=OSError("disk unavailable")):
            with self.assertRaises(OSError):
                self.delivery.admit(1, "coordinator", A)
        self.assertEqual(self.admission_calls, 0)

    def test_unadmitted_conflict_does_not_claim_readmission_is_needed(self):
        self.observed["mergeStateStatus"] = "DIRTY"
        self.delivery.observe(1, "owner")
        self.observed["mergeStateStatus"] = "CLEAN"
        self.assertEqual(self.delivery.observe(1, "owner")["queue_state"], "not_admitted")

    def test_label_timeout_keeps_intent_and_worker_recovers_after_session_loss(self):
        self.admission_timeout = True
        with self.assertRaises(subprocess.TimeoutExpired):
            self.delivery.admit(1, "coordinator", A)
        saved = self.delivery.read()["requests"]["1"]
        self.assertTrue(saved["queue_admission_error"])
        self.assertEqual(saved["queue_owner"], "coordinator")
        self.merge()
        reopened = module.Delivery(self.state, self.root, self.run_command)
        self.assertEqual(reopened.supervise()["phase"], "deferred")
        self.returncode, self.make_receipt = 0, True
        self.assertEqual(reopened.supervise()["phase"], "running")
        result = reopened.read()["requests"]["1"]
        self.assertEqual(result["receipt"]["sha"], B)
        self.assertEqual(result["queue_owner"], "coordinator")

    def test_merge_during_admission_stays_pending_without_foreground_install(self):
        self.merge_during_admission = True
        result = self.delivery.admit(1, "coordinator", A)
        self.assertEqual(result["status"], "deployment_pending")
        self.assertEqual((result["merged_sha"], result["target_sha"]), (A, B))
        self.assertEqual(self.install_count, 0)

    def test_queue_conflict_readmission_and_hold_are_distinct(self):
        self.delivery.admit(1, "coordinator", A)
        first = self.delivery.read()["requests"]["1"]["queue_first_requested_at"]
        self.observed.update(mergeStateStatus="DIRTY", labels=[])
        self.assertEqual(self.delivery.observe(1, "worker")["queue_state"], "conflict")
        self.observed["mergeStateStatus"] = "CLEAN"
        self.assertEqual(self.delivery.observe(1, "worker")["queue_state"], "awaiting_readmission")
        result = self.delivery.admit(1, "coordinator", A)
        self.assertEqual(result["queue_first_requested_at"], first)
        self.assertEqual(result["queue_state"], "queued")
        self.observed["labels"].append({"name": "queue-hold"})
        self.assertEqual(self.delivery.observe(1, "worker")["queue_state"], "held")

    def test_admitted_requests_coalesce_after_owner_disappears_and_safe_deferral(self):
        for pr in (1, 2, 3):
            self.delivery.admit(pr, "coordinator", A)
        self.merge()
        reopened = module.Delivery(self.state, self.root, self.run_command)
        self.install_output = "deployment deferred: preview reserved by owner\n"
        self.assertEqual(reopened.supervise()["phase"], "deferred")
        self.assertEqual(self.install_count, 1)
        self.returncode, self.make_receipt = 0, True
        self.assertEqual(reopened.supervise()["phase"], "running")
        for request in reopened.read()["requests"].values():
            self.assertEqual(request["status"], "running")
            self.assertEqual(request["receipt"]["sha"], B)
        self.assertEqual(self.install_count, 2)

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

    def test_deferral_status_shows_the_current_blocker_without_build_noise(self):
        self.merge()
        self.install_output = "signing output\n" * 500 + "deployment deferred: preview reserved by owner; deployment pending for retry: " + B + "\n"
        result = self.delivery.step(1, "owner")
        self.assertEqual(result["status"], "deployment_pending")
        self.assertEqual(result["last_error"], "preview reserved by owner")
        self.assertIn("signing output", Path(result["log"]).read_text())
        self.install_output = ""
        result = self.delivery.step(1, "owner")
        self.assertEqual(result["last_error"], "Activation deferred; see the delivery log")

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
