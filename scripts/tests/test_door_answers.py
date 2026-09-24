#!/usr/bin/env python3
"""The door-answer check catches the shape it was written for, and only that.

A check nobody has watched fail is a check nobody knows works. This drives the
real script over the real 23 Sep bug and over the shapes that are fine.
"""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "check-door-answers.py"


class DoorAnswerCheck(unittest.TestCase):
    def run_over(self, source: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            server = pathlib.Path(tmp) / "tb-voice" / "server"
            server.mkdir(parents=True)
            (server / "manager.py").write_text(source)
            # The script finds the tree from its own location, so it is copied
            # beside a throwaway one rather than pointed at the real repo.
            scripts = pathlib.Path(tmp) / "scripts"
            scripts.mkdir()
            (scripts / CHECK.name).write_text(CHECK.read_text())
            return subprocess.run([sys.executable, str(scripts / CHECK.name)],
                                  capture_output=True, text=True)

    def test_the_bug_that_made_every_agent_the_manager(self):
        """Verbatim shape of _voice_for before the fix."""
        result = self.run_over(
            'async def _voice_for(self, session_id):\n'
            '    code, out = await _run(TBASE, "voice", session_id, "--json")\n'
            '    data = _json_or_text(code, out)\n'
            '    voice = data.get("cloud") if isinstance(data, dict) else None\n'
            '    return voice or None\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cloud", result.stderr)

    def test_the_same_mistake_on_one_line(self):
        result = self.run_over(
            'voice = _json_or_text(code, out).get("cloud")\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_unwrapping_first_is_fine(self):
        result = self.run_over(
            'data = _json_or_text(code, out).get("data") or {}\n'
            'voice = data.get("cloud")\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_using_the_envelope_whole_is_fine(self):
        """What every tool does: hand the wrapper back to the caller."""
        result = self.run_over(
            'await params.result_callback(_json_or_text(code, out))\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reading_the_envelope_s_own_keys_is_fine(self):
        result = self.run_over(
            'answer = _json_or_text(code, out)\n'
            'if answer.get("exit") != 0:\n'
            '    return answer.get("text")\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
