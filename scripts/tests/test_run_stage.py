#!/usr/bin/env python3
"""Prove progress, nonzero outcomes and cleanup with actual child processes."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

TOOL = Path(__file__).resolve().parents[1] / "run-stage.py"


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stage-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "stage.log"

    def command(self, source, timeout=5):
        return [sys.executable, str(TOOL), "--timeout", str(timeout), "--log", str(self.log),
                "--", sys.executable, "-u", "-c", source]

    def test_failure_is_preserved_with_complete_progress(self):
        result = subprocess.run(self.command("print('test started'); print('assertion failed'); exit(7)"),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("assertion failed", self.log.read_text())
        self.assertIn("test started", result.stderr)

    def test_progress_reaches_observer_before_completion(self):
        with subprocess.Popen(self.command("import time; print('test started'); time.sleep(1); print('finished')"),
                              stderr=subprocess.PIPE, text=True) as child:
            self.assertEqual(child.stderr.readline().strip(), "test started")
            self.assertIsNone(child.poll())
            self.assertEqual(child.wait(timeout=10), 0)

    def test_timeout_diagnoses_and_kills_term_ignoring_descendant(self):
        pidfile = self.root / "child.pid"
        source = f"""import subprocess,sys,time,signal
signal.signal(signal.SIGTERM, signal.SIG_IGN)
p=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])
open({str(pidfile)!r},'w').write(str(p.pid))
print('stalled test started',flush=True)
time.sleep(60)
"""
        result = subprocess.run(self.command(source, 0.5), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn("stalled test started", self.log.read_text())
        self.assertIn("timed out", self.log.read_text())
        self.assertTrue(self.log.with_suffix(".processes.txt").exists())
        pid = pidfile.read_text()
        status = subprocess.run(["ps", "-p", pid, "-o", "stat="], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not status or status.startswith("Z"), status)

    def test_cancellation_is_not_success_and_retains_diagnostics(self):
        with subprocess.Popen(self.command("import time; print('started'); time.sleep(60)"),
                              stderr=subprocess.PIPE, text=True) as child:
            self.assertEqual(child.stderr.readline().strip(), "started")
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=15), 143)
        self.assertIn("interrupted", self.log.read_text())
        self.assertTrue(self.log.with_suffix(".processes.txt").exists())

    def started_command(self, source, timeout=10, quiet=0.5):
        return [sys.executable, str(TOOL), "--timeout", str(timeout), "--log", str(self.log),
                "--start-marker", "Test Suite", "--start-quiet", str(quiet),
                "--", sys.executable, "-u", "-c", source]

    def test_a_stall_before_any_test_is_retried_once(self):
        # First attempt builds and then goes silent, as swift-test did on
        # 30 Sep; the second starts its tests and passes.
        counter = self.root / "attempts"
        source = f"""import time,pathlib
p=pathlib.Path({str(counter)!r}); n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1))
print('Build complete!')
if n == 0: time.sleep(30)
print("Test Suite 'All tests' passed")
"""
        result = subprocess.run(self.started_command(source), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counter.read_text(), "2")
        self.assertIn("no test ran", self.log.read_text())
        self.assertIn("retrying: attempt 2", self.log.read_text())
        self.assertTrue(self.log.with_suffix(".stall1.processes.txt").exists())

    def test_a_stall_that_keeps_happening_still_fails(self):
        result = subprocess.run(self.started_command("import time; print('Build complete!'); time.sleep(30)"),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(self.log.read_text().count("no test ran"), 2)

    def test_a_stall_after_tests_start_is_not_retried(self):
        # Once a test has run, silence is the test's, and retrying could hide it.
        source = "import time; print(\"Test Suite 'All tests' started\"); time.sleep(30)"
        result = subprocess.run(self.started_command(source, timeout=1.5), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertNotIn("retrying", self.log.read_text())
        self.assertIn("timed out", self.log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
