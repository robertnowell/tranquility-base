#!/usr/bin/env python3
"""Run the real test wrapper against missing, failed and growing test inventories."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


class TestGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tb-test-gate-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SOURCE / "scripts/test.sh", self.root / "scripts/test.sh")
        shutil.copy2(SOURCE / "scripts/run-stage.py", self.root / "scripts/run-stage.py")
        binary = self.root / "bin"
        binary.mkdir()
        swift = binary / "swift"
        swift.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["GATE_CALLS"], "a") as f: f.write(json.dumps(args) + "\\n")
framework = "XC" if "--enable-xctest" in args else "ST"
count = int(os.environ.get("GATE_" + framework, "2103" if framework == "XC" else "66"))
if "list" in args:
    if os.environ.get("GATE_DISCOVERY_FAIL") == framework: sys.exit(2)
    count = int(os.environ.get("GATE_DISCOVER_" + framework, str(count)))
    for i in range(count): print(f"TranquilityCoreTests.Example/test{i}")
elif framework == "XC":
    if os.environ.get("GATE_LOAD_FAIL"): print("bundle couldn't be loaded: incompatible architecture")
    if not os.environ.get("GATE_NO_XC_SUMMARY"):
        print("Test Suite 'All tests' passed")
        print(f"Executed {count} tests, with 0 failures")
else:
    print(f"Test run with {count} tests in 4 suites passed")
if os.environ.get("GATE_FAIL") == framework: sys.exit(1)
''')
        swift.chmod(0o755)
        self.calls = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        GATE_CALLS=str(self.calls))

    def gate(self, **settings):
        return subprocess.run(["bash", "scripts/test.sh"], cwd=self.root,
                              env=dict(self.env, **settings), text=True, capture_output=True)

    def test_growth_needs_no_shared_count_edit(self):
        result = self.gate(GATE_XC="2120", GATE_ST="70")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2120 XCTest + 70 swift-testing", result.stdout)
        self.assertNotIn("raise FLOOR", result.stdout)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 4)
        self.assertIn("--disable-swift-testing", calls[0])
        self.assertIn("--disable-xctest", calls[1])
        self.assertTrue(all("--skip-build" in call for call in calls[2:]))

    def test_discovered_tests_cannot_be_omitted_even_above_baseline(self):
        for framework, count in (("XC", "2104"), ("ST", "67")):
            with self.subTest(framework=framework):
                result = self.gate(**{"GATE_DISCOVER_" + framework: count})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("discovered", result.stderr)

    def test_discovery_collapse_cannot_lower_the_coverage_guard(self):
        for framework, count in (("XC", "2102"), ("ST", "65")):
            with self.subTest(framework=framework):
                result = self.gate(**{"GATE_" + framework: count})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("baseline", result.stderr)

    def test_either_discovery_failure_blocks_success(self):
        for framework in ("XC", "ST"):
            with self.subTest(framework=framework):
                result = self.gate(GATE_DISCOVERY_FAIL=framework)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("discovery failed", result.stderr)

    def test_zero_tests_or_absent_xctest_summary_cannot_pass(self):
        for settings in ({"GATE_XC": "0"}, {"GATE_ST": "0"}, {"GATE_NO_XC_SUMMARY": "1"}):
            with self.subTest(settings=settings):
                self.assertNotEqual(self.gate(**settings).returncode, 0)

    def test_a_success_summary_cannot_mask_either_framework_failure(self):
        for framework in ("XC", "ST"):
            with self.subTest(framework=framework):
                result = self.gate(GATE_FAIL=framework)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("swift test exited", result.stderr)

    def test_wrong_architecture_reports_the_load_failure(self):
        result = self.gate(GATE_LOAD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
