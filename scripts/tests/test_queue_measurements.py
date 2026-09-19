#!/usr/bin/env python3
"""Queue timing must retain recovery waiting and previously observed attempts."""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("queue_measurements", Path(__file__).resolve().parents[1] / "measure-merge-queue.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class QueueMeasurementTests(unittest.TestCase):
    def sample(self):
        return {"repo": module.REPO, "checked_at": "2026-09-17T22:25:00Z", "runs": [], "prs": [{
            "number": 7, "state": "MERGED", "headRefOid": "a" * 40,
            "mergedAt": "2026-09-17T22:21:51Z", "timeline": [
                {"event": "labeled", "created_at": "2026-09-17T22:15:20Z", "label": {"name": "merge-queue"}},
                {"event": "unlabeled", "created_at": "2026-09-17T22:16:08Z", "label": {"name": "merge-queue"}},
                {"event": "labeled", "created_at": "2026-09-17T22:21:44Z", "label": {"name": "merge-queue"}}]}]}

    def test_readmission_does_not_erase_conflict_and_recovery_wait(self):
        result = module.report([self.sample()])
        self.assertEqual(result["prs"][0]["request_to_merge_seconds"], 391)
        self.assertEqual(result["prs"][0]["admission_requests"], 2)
        self.assertEqual(result["request_to_merge_max_seconds"], 391)
        self.assertEqual(result["checked_at"], "2026-09-17T22:25:00Z")
        self.assertIn("observation_age_seconds", result)

    def test_open_and_never_admitted_prs_do_not_look_like_fast_merges(self):
        sample = self.sample()
        pr = sample["prs"][0]
        pr.update(state="OPEN", mergedAt=None)
        result = module.report([sample])
        self.assertEqual(result["merged_samples"], 0)
        self.assertIsNone(result["request_to_merge_median_seconds"])
        self.assertGreater(result["prs"][0]["open_wait_seconds"], 0)
        pr["timeline"] = []
        pr.update(state="MERGED", mergedAt="2026-09-17T22:21:51Z")
        self.assertIsNone(module.report([sample])["prs"][0]["request_to_merge_seconds"])

    def test_cohort_changes_cannot_silently_drop_the_slow_pr(self):
        first = self.sample()
        last = copy.deepcopy(first)
        last["prs"] = []
        with self.assertRaisesRegex(ValueError, "cohort"):
            module.report([first, last])
        first["repo"] = "somewhere/else"
        with self.assertRaisesRegex(ValueError, "repository"):
            module.report([first])
        with self.assertRaises(ValueError):
            module.report([])

    def test_previous_attempt_and_cancellation_survive_a_rerun(self):
        first = self.sample()
        run = {"id": 42, "run_attempt": 1, "head_sha": "a" * 40, "created_at": "2026-09-17T22:16:00Z",
               "jobs": [{"name": "Source audit", "conclusion": "cancelled", "started_at": "2026-09-17T22:16:03Z",
                         "completed_at": "2026-09-17T22:17:03Z"}]}
        first["runs"] = [run]
        last = copy.deepcopy(first)
        last["runs"][0]["run_attempt"] = 2
        last["runs"][0]["jobs"][0]["conclusion"] = "success"
        result = module.report([first, first, last])
        self.assertEqual([j["attempt"] for j in result["jobs"]], [1, 2])
        self.assertEqual(result["jobs"][0]["execution_seconds"], 60)
        self.assertEqual(result["jobs"][0]["run_created_to_job_start_seconds"], 3)

    def test_collection_paginates_timeline_and_branch_scoped_runs_and_jobs(self):
        calls = []
        pr = self.sample()["prs"][0]
        pr["headRefName"] = "feature/space in branch"
        run = {"id": 42, "run_attempt": 1, "head_sha": "a" * 40, "head_branch": pr["headRefName"]}
        def gh(*args):
            calls.append(args)
            if args[:2] == ("pr", "view"):
                return dict(pr)
            self.assertEqual(args[0], "api")
            self.assertEqual(args[-2:], ("--paginate", "--slurp"))
            if "/timeline?" in args[1]:
                return [[pr["timeline"][0]], pr["timeline"][1:]]
            if "/jobs?" in args[1]:
                return [{"jobs": [{"id": 1}]}, {"jobs": [{"id": 2}]}]
            self.assertIn("branch=feature%2Fspace+in+branch", args[1])
            self.assertIn("event=pull_request", args[1])
            return [{"workflow_runs": []}, {"workflow_runs": [run]}]
        with patch.object(module, "gh", side_effect=gh):
            result = module.collect([7])
        self.assertEqual(len(result["prs"][0]["timeline"]), 3)
        self.assertEqual(len(result["runs"][0]["jobs"]), 2)
        self.assertEqual(len(calls), 4)

    def test_api_failure_is_an_error_instead_of_an_empty_queue(self):
        with patch.object(module, "gh", side_effect=TimeoutError("unavailable")):
            with self.assertRaises(TimeoutError):
                module.collect([7])


if __name__ == "__main__":
    unittest.main(verbosity=2)
