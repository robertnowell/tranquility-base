#!/usr/bin/env python3
"""The compat check gives one verdict per tree, whatever the day is."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
CHECK = SOURCE / "scripts/check-compat-comments.sh"


class CompatCommentTests(unittest.TestCase):
    def check(self, line):
        with tempfile.TemporaryDirectory(prefix="tb-compat-") as temp:
            sources = Path(temp) / "Sources"
            sources.mkdir()
            (sources / "fixture.swift").write_text(line + "\n")
            return subprocess.run(
                [sys.executable, str(CHECK), "--root", temp],
                text=True, capture_output=True,
            )

    def test_a_date_long_past_does_not_fail_the_tree(self):
        # 16 Nov 2026: a date of 2026-11-15 passed and every pull request
        # failed. The year 2000 has passed on every day this test can run.
        result = self.check("// COMPAT(old): kept for a reason, remove after 2000-01-01")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("COMPAT(old)", result.stdout)

    def test_a_marker_without_a_date_passes(self):
        result = self.check("// COMPAT(shim): remove when the reader lands")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_form_is_still_refused(self):
        for line, why in (
            ("// COMPAT shim: no parentheses", "is not COMPAT(name)"),
            ("// COMPAT(): a reason", "has no name"),
            ("// COMPAT(shim):", "does not say what ends it"),
        ):
            with self.subTest(line=line):
                result = self.check(line)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(why, result.stdout)

    def test_prose_about_the_marker_is_exempt(self):
        result = self.check("// the COMPAT form is explained here  compat:exempt")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_the_check_never_reads_the_clock(self):
        code = CHECK.read_text().split('"""', 2)[2]
        for word in ("datetime", "time.", "today(", "now("):
            self.assertNotIn(word, code, f"the verdict must not depend on the day: {word}")

    def test_the_real_tree_is_clean(self):
        result = subprocess.run([sys.executable, str(CHECK)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
