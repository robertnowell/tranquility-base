#!/usr/bin/env python3
"""Exercise actual build/lease locks and pinned artifacts using a disposable repository."""
import fcntl
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepared", SOURCE / "scripts/prepare-dev.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
state_spec = importlib.util.spec_from_file_location("state", SOURCE / "scripts/deployment-state.py")
state_module = importlib.util.module_from_spec(state_spec); state_spec.loader.exec_module(state_module)


class PreparedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="prepared-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"; (self.repo / "scripts").mkdir(parents=True)
        self.clean = self.base / "clean"; (self.clean / ".build/debug").mkdir(parents=True)
        (self.clean / ".build/debug/tbase").write_text("fixture executable")
        self.raw = self.clean / "Dev.app"
        (self.raw / "Contents/MacOS").mkdir(parents=True)
        (self.raw / "Contents/MacOS/TranquilityApp").write_text("fixture executable")
        self.cache = self.base / "cache"
        self.gate = self.base / "build-go"
        self.started = self.base / "build-started"
        build = self.repo / "scripts/build-clean.sh"
        build.write_text(f'''#!/usr/bin/env python3
from pathlib import Path
import time
Path({str(self.started)!r}).write_text('started')
while not Path({str(self.gate)!r}).exists(): time.sleep(.01)
print({str(self.raw)!r})
'''); build.chmod(0o755)
        self.gate.touch()
        binary = self.base / "bin"; binary.mkdir()
        for name, text in {"swift": "echo fixture-toolchain", "xcrun": "echo fixture-sdk",
                           "lipo": "echo arm64", "codesign": "exit 0"}.items():
            p = binary / name; p.write_text("#!/bin/bash\n" + text + "\n"); p.chmod(0o755)
        self.patches = [patch.object(module, "ROOT", self.repo), patch.object(module, "CACHE", self.cache),
                        patch.object(module, "CLEAN", self.clean),
                        patch.dict(os.environ, PATH=str(binary)+os.pathsep+os.environ["PATH"],
                                   GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")]
        for p in self.patches: p.start(); self.addCleanup(p.stop)
        self.git("init", "-qb", "main"); self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("add", "scripts/build-clean.sh"); self.git("commit", "-qm", "fixture")
        self.sha = self.git("rev-parse", "HEAD")
        (self.raw / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "TBSourceCommit": self.sha, "TBAppChannel": "development"}))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def prepare(self):
        artifact, app, lease = module.prepare(self.sha)
        self.addCleanup(lease.close)
        return artifact, app, lease

    def test_build_does_not_own_app_lock_and_second_builder_defers(self):
        self.gate.unlink()
        result = []
        worker = threading.Thread(target=lambda: result.append(self.prepare()))
        worker.start()
        try:
            limit = time.monotonic() + 5
            while not self.started.exists() and time.monotonic() < limit: time.sleep(.01)
            self.assertTrue(self.started.exists())
            state = state_module.DeploymentState(self.base / "state", self.base / "app.lock")
            token = state.acquire(os.getpid()); state.unlock(os.getpid(), token)
            with self.assertRaises(BlockingIOError): module.prepare(self.sha)
        finally:
            self.gate.touch(); worker.join(timeout=10)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(result), 1)

    def test_later_build_workspace_changes_cannot_change_artifact(self):
        artifact, app, lease = self.prepare()
        (self.raw / "Contents/MacOS/TranquilityApp").write_text("different build")
        (self.repo / "scripts/build-clean.sh").write_text("different script")
        self.assertEqual((app / "Contents/MacOS/TranquilityApp").read_text(), "fixture executable")
        self.assertIn("build-started", (artifact / "scripts/build-clean.sh").read_text())
        module.verify(artifact, self.sha)

    def test_source_and_verification_tool_changes_are_rejected(self):
        artifact, app, lease = self.prepare()
        with self.assertRaises(ValueError): module.verify(artifact, "0" * 40)
        script = artifact / "scripts/build-clean.sh"; script.write_text("changed")
        with self.assertRaises(ValueError): module.verify(artifact, self.sha)

    def test_artifact_is_reused_without_building_again(self):
        first, _, _ = self.prepare()
        self.started.unlink(); self.gate.unlink()
        second, _, _ = self.prepare()
        self.assertEqual(first, second)
        self.assertFalse(self.started.exists())

    def test_old_artifact_is_not_removed_while_leased(self):
        artifact, app, lease = self.prepare()
        old = time.time() - 90000; os.utime(artifact, (old, old))
        module.prune(self.cache, None)
        self.assertTrue(app.exists())
        lease.close(); module.prune(self.cache, None)
        self.assertFalse(artifact.exists())

    def test_wrong_source_in_a_successful_build_never_publishes_artifact(self):
        (self.raw / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "TBSourceCommit": "0" * 40, "TBAppChannel": "development"}))
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(list(self.cache.glob("artifact-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
