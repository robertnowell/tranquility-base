#!/usr/bin/env python3
"""All state and locks are temporary; these tests never install or launch apps."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


TOOL = Path(__file__).resolve().parents[1] / "deployment-state.py"
spec = importlib.util.spec_from_file_location("deployment_state", TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DeploymentState, Blocked = module.DeploymentState, module.Blocked
A, B = "a" * 40, "b" * 40


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tb-preview-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.clock = 1000
        self.state = DeploymentState(root / "state", root / "mutation.lock", lambda: self.clock)
        self.pid = os.getpid()
        self.lock = self.state.acquire(self.pid)

    def reserve(self, sha=A, token=""):
        return self.state.reserve(self.pid, self.lock, "preview-owner", sha, "dev", 2, token)

    def authorize(self, sha=B, channel="dev", token="", unmerged=False):
        self.state.authorize(self.pid, self.lock, "install", sha, channel, "merge-owner", token, unmerged)

    def test_exact_owner_target_and_channel_are_allowed(self):
        token = self.reserve()
        self.authorize(A, token=token, unmerged=True)
        self.assertEqual(self.state.read()["pending"], [])

    def test_main_other_preview_and_prod_switch_cannot_replace_preview(self):
        token = self.reserve()
        for sha, channel, supplied in ((B, "dev", ""), (B, "dev", token), (A, "prod", token), (A, "dev", "")):
            with self.subTest(sha=sha, channel=channel, supplied=bool(supplied)):
                with self.assertRaises(Blocked):
                    self.authorize(sha, channel, supplied)
        pending = self.state.read()["pending"]
        self.assertTrue(pending)
        self.assertTrue(all(p["retry_owner"] == "merge-owner" for p in pending))

    def test_unmerged_source_always_needs_a_current_reservation(self):
        with self.assertRaises(Blocked):
            self.authorize(A, unmerged=True)
        token = self.reserve()
        self.clock += 121
        with self.assertRaises(Blocked):
            self.authorize(A, token=token, unmerged=True)

    def test_expiry_allows_main_but_does_not_execute_or_discard_pending_work(self):
        self.reserve()
        with self.assertRaises(Blocked):
            self.authorize()
        self.clock += 121
        self.authorize()
        status = self.state.status()
        self.assertFalse(status["preview"]["active"])
        self.assertEqual(len(status["pending"]), 1)

    def test_handoff_rotates_token_and_stale_release_cannot_clear_new_owner(self):
        old = self.reserve()
        new = self.reserve(B, old)
        self.assertNotEqual(old, new)
        with self.assertRaises(Blocked):
            self.state.release(self.pid, self.lock, old)
        self.authorize(B, token=new, unmerged=True)

    def test_another_owner_cannot_steal_a_live_preview(self):
        self.reserve()
        with self.assertRaises(Blocked):
            self.reserve(B)

    def test_pending_intent_survives_reopen_and_release(self):
        token = self.reserve()
        for _ in range(2):
            with self.assertRaises(Blocked):
                self.authorize()
        self.state.release(self.pid, self.lock, token)
        reopened = DeploymentState(self.state.state_dir, self.state.lock_dir)
        self.assertEqual(len(reopened.read()["pending"]), 1)
        self.assertEqual(reopened.read()["pending"][0]["sha"], B)

    def test_status_hides_token_without_mutating_persisted_state(self):
        token = self.reserve()
        self.assertNotIn("token", self.state.status()["preview"])
        self.assertEqual(self.state.read()["preview"]["token"], token)
        self.assertEqual(self.state.path.stat().st_mode & 0o777, 0o600)

    def test_unknown_or_corrupt_state_blocks_authorization(self):
        for contents in ('{', '{"version":2,"pending":[]}', '{"version":1,"pending":[],"preview":{}}',
                         '{"version":1,"pending":[null],"preview":null}',
                         json.dumps({"version": 1, "pending": [], "preview": {
                             "owner": "x", "token": "x", "sha": A, "channel": "dev", "expires_at": float("nan")}})):
            with self.subTest(contents=contents):
                self.state.path.write_text(contents)
                with self.assertRaises(Blocked):
                    self.authorize()

    def test_exec_can_reuse_lock_but_another_process_cannot(self):
        self.assertEqual(self.state.acquire(self.pid, self.lock), self.lock)
        with self.assertRaises(Blocked):
            self.state.authorize(self.pid + 1, self.lock, "switch", B, "prod", "other")
        with self.assertRaises(Blocked):
            self.state.unlock(self.pid + 1, self.lock)

    def test_stale_unlock_cannot_release_a_new_lock(self):
        old = self.lock
        self.state.unlock(self.pid, old)
        self.lock = self.state.acquire(self.pid)
        with self.assertRaises(Blocked):
            self.state.unlock(self.pid, old)
        self.assertEqual(self.state.lock_owner()["token"], self.lock)

    def test_live_legacy_writer_and_initializing_lock_are_respected(self):
        self.state.unlock(self.pid, self.lock)
        self.state.lock_dir.mkdir()
        (self.state.lock_dir / "pid").write_text(str(self.pid))
        with self.assertRaises(Blocked):
            self.state.acquire(self.pid)
        (self.state.lock_dir / "pid").unlink()
        os.utime(self.state.lock_dir, (self.clock, self.clock))
        with self.assertRaisesRegex(Blocked, "initializing"):
            self.state.acquire(self.pid)

    def test_crashed_writer_releases_authority_and_preview_survives(self):
        token = self.reserve()
        self.state.unlock(self.pid, self.lock)
        program = '''import importlib.util, os, sys
spec=importlib.util.spec_from_file_location("state", sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
s=m.DeploymentState(sys.argv[2], sys.argv[3])
print(s.acquire(os.getpid()), flush=True)
sys.stdin.readline()
'''
        child = subprocess.Popen(
            [sys.executable, "-c", program, str(TOOL), str(self.state.state_dir), str(self.state.lock_dir)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(child.stdout.readline().strip())
            with self.assertRaises(Blocked):
                self.state.acquire(self.pid)
        finally:
            child.communicate("exit\n", timeout=5)
        self.lock = self.state.acquire(self.pid)
        self.assertEqual(self.state.read()["preview"]["token"], token)


class EntrypointTests(unittest.TestCase):
    """Run the actual shell guards with isolated state, bundles and git remote.

    App/process helpers and mutation commands are tripwires. A guard moved past
    a stop, copy, build, launch, or signing command makes these tests fail.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tb-preview-entrypoint-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "scripts"
        (scripts / "lib").mkdir(parents=True)
        (self.repo / ".gitignore").write_text("logs/\n")
        self.state = DeploymentState(self.root / "state", self.root / "mutation.lock")
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        for name in ("TB_PREVIEW_TOKEN", "TB_DEPLOY_LOCK_TOKEN"):
            self.env.pop(name, None)
        self.env["TB_DEPLOY_OWNER"] = "fixture-retry-owner"
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["TB_TEST_MUTATIONS"] = str(self.root / "mutations")
        for name in ("relaunch.sh", "install-dev.sh", "install.sh", "switch-app.sh"):
            text = (TOOL.parent / name).read_text()
            text = text.replace("/Applications", str(self.root / "Applications"))
            text = text.replace("/private/tmp/tb-clean", str(self.root / "clean"))
            text = text.replace("$HOME/Library", str(self.root / "Library"))
            path = scripts / name
            path.write_text(text)
            path.chmod(0o755)
        shutil.copy2(TOOL.parent / "lib/deployment.sh", scripts / "lib/deployment.sh")
        # Redirect only state paths, retaining the real CLI and shell adapter.
        (scripts / "deployment-state.py").write_text(f'''import importlib.util, sys
spec=importlib.util.spec_from_file_location("state", {str(TOOL)!r})
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=m.DeploymentState
m.DeploymentState=lambda *args: original({str(self.state.state_dir)!r}, {str(self.state.lock_dir)!r})
sys.exit(m.main())
''')
        (scripts / "lib/paths.sh").write_text(f'tb_bundle_dir() {{ printf "%s\\n" "{self.root}/bundles"; }}\n')
        (scripts / "lib/app-process.sh").write_text('''app_at_path_running() { return 1; }
app_running() { return 1; }
app_stop() { echo stop >> "$TB_TEST_MUTATIONS"; exit 99; }
app_stop_path() { echo stop_path >> "$TB_TEST_MUTATIONS"; exit 99; }
wait_for_microphone() { echo capture_check >> "$TB_TEST_MUTATIONS"; exit 99; }
''')
        binary = self.root / "bin"
        binary.mkdir()
        tripwire = '#!/bin/bash\necho "${0##*/}" >> "$TB_TEST_MUTATIONS"\nexit 99\n'
        for name in ("cp", "rm", "open", "launchctl", "codesign", "xattr"):
            path = binary / name
            path.write_text(tripwire)
            path.chmod(0o755)
        for name in ("build-clean.sh", "bundle-dev.sh"):
            path = scripts / name
            path.write_text(tripwire)
            path.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + os.environ["PATH"]
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Deployment fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.sha = self.git("rev-parse", "HEAD")
        remote = self.root / "remote.git"
        self.git("clone", "-q", "--bare", str(self.repo), str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("fetch", "-q", "origin")
        for channel, suffix in (("dev", " Dev"), ("prod", "")):
            contents = self.root / "Applications" / f"Tranquility Base{suffix}.app" / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.robertnowell.voice-dispatch" + (".dev" if channel == "dev" else ""),
                "TBSourceCommit": self.sha, "TBAppChannel": "development", "TBUpdatesEnabled": False,
            }))
        lock = self.state.acquire(os.getpid())
        self.token = self.state.reserve(os.getpid(), lock, "protected-preview", A, "dev", 120)
        self.state.unlock(os.getpid(), lock)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, text=True,
                              capture_output=True, check=True).stdout.strip()

    def test_all_four_mutation_paths_defer_before_touching_an_app(self):
        apps = self.root / "Applications"
        commands = (
            ("relaunch.sh", "origin/main"),
            ("install-dev.sh", str(apps / "Tranquility Base Dev.app"), "--activate"),
            ("install-dev.sh",),  # Also protect the implicit source build.
            ("install.sh", str(apps / "Tranquility Base.app"), "--no-login-item"),
            ("switch-app.sh", "dev"),
            ("switch-app.sh", "prod"),
        )
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(["bash", "scripts/" + command[0], *command[1:]],
                                        cwd=self.repo, env=self.env, text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
                self.assertIn("preview reserved by protected-preview", result.stderr)
                self.assertFalse((self.root / "mutations").exists(), result.stdout + result.stderr)
                self.assertFalse(self.state.lock_dir.exists())
                self.assertEqual(self.state.read()["preview"]["token"], self.token)
        pending = self.state.read()["pending"]
        self.assertEqual(len(pending), 5)
        self.assertTrue(all(p["sha"] == self.sha and p["retry_owner"] == "fixture-retry-owner" for p in pending))

    def test_shell_exec_reuses_lock_and_exit_releases_it(self):
        script = self.repo / "scripts/exec-fixture.sh"
        script.write_text('''#!/bin/bash
set -euo pipefail
. scripts/lib/deployment.sh
tb_deployment_lock
trap tb_deployment_unlock EXIT
if [ "${1:-}" != child ]; then exec bash "$0" child; fi
tb_deployment_authorize fixture "''' + A + '''" dev 1
''')
        result = subprocess.run(["bash", str(script)], cwd=self.repo,
                                env=dict(self.env, TB_PREVIEW_TOKEN=self.token),
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.state.lock_dir.exists())

    def test_automatic_delivery_preserves_quit_and_selected_prod(self):
        helper = self.repo / "scripts/lib/app-process.sh"
        for prod in (False, True):
            with self.subTest(prod=prod):
                if prod:
                    helper.write_text('''app_at_path_running() { [[ "$1" == *"Tranquility Base.app" ]]; }
app_running() { return 0; }
''')
                result = subprocess.run(["bash", "scripts/relaunch.sh", "origin/main"],
                                        cwd=self.repo, env=dict(self.env, TB_DEPLOY_AUTOMATIC="1"),
                                        text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
                self.assertIn("Prod is selected" if prod else "does not undo Quit", result.stderr)
                self.assertFalse((self.root / "mutations").exists())
                self.assertFalse(self.state.lock_dir.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
