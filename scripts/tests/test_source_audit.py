#!/usr/bin/env python3
"""Exercise the real audit boundary without compiling or touching the live app."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2]


class SourceAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tb-source-audit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.log = self.root / "steps.log"
        self.env = dict(os.environ, AUDIT_TEST_LOG=str(self.log))
        # Ignore user-level git configuration, signing and hooks in these fixtures.
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q", "-b", "candidate")
        self.git("config", "user.name", "Audit fixture")
        self.git("config", "user.email", "audit@example.invalid")
        self.git("config", "core.hooksPath", os.devnull)
        (self.repo / "scripts/tests").mkdir(parents=True)
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/fixture.swift").write_text("// fixture\n")
        shutil.copy2(SOURCE / "scripts/audit-source.sh", self.repo / "scripts/audit-source.sh")
        shutil.copy2(SOURCE / "scripts/preflight.sh", self.repo / "scripts/preflight.sh")
        for name in (
            "check-key-names.sh", "check-house-copy.sh", "check-alerts.sh", "check-borrowed-descriptors.sh",
            "check-compat-comments.sh", "check-row-dates.sh", "tests/test_source_audit.py",
            "tests/test_deployment_state.py",
            "tests/test_delivery.py",
            "tests/test_queue_measurements.py",
            "tests/test_test_gate.py",
            "tests/test_run_stage.py",
            "tests/test_prepared_dev.py",
        ):
            (self.repo / "scripts" / name).write_text(
                "import os\nfrom pathlib import Path\n"
                "with open(os.environ['AUDIT_TEST_LOG'], 'a') as log:\n"
                "    log.write(Path(__file__).name + '\\n')\n"
            )
        for name in (
            "test-attribution.sh", "test-notary-log-parser.sh", "test-release-tag-verification.sh",
            "test-debug-symbols.sh", "test.sh", "test-dev-lanes.sh", "test-dispatch-tmux.sh",
            "test-past-agents-search.sh",
            "test-credits-onboarding.sh",
        ):
            path = self.repo / "scripts" / name
            path.write_text('''#!/bin/bash
set -eu
printf '%s\n' "${0##*/}" >> "$AUDIT_TEST_LOG"
if [ "${0##*/}" = "test.sh" ]; then
  if [ "${AUDIT_TEST_FAIL:-0}" = 1 ]; then
    echo 'error: deliberately failing test fixture' >&2
    exit 1
  fi
  case "${AUDIT_TEST_MUTATE:-}" in
    main) git update-ref refs/remotes/origin/main "$AUDIT_TEST_OTHER" ;;
    head) git checkout -q --detach "$AUDIT_TEST_OTHER" ;;
    dirty) echo '// modified during audit' >> Sources/fixture.swift ;;
  esac
  echo '✓ 1 XCTest, 1 Swift Testing (fixture)'
fi
''')
            path.chmod(0o755)
        binary = self.root / "bin"
        binary.mkdir()
        swift = binary / "swift"
        swift.write_text('#!/bin/bash\nprintf "swift %s\\n" "$*" >> "$AUDIT_TEST_LOG"\n')
        swift.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + os.environ["PATH"]
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.base = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.git("commit", "--allow-empty", "-qm", "candidate")
        self.candidate = self.git("rev-parse", "HEAD")
        # A sibling main commit, so it does not contain the candidate.
        self.other = self.git("commit-tree", "HEAD^{tree}", "-p", self.base, "-m", "other main change")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=self.env, text=True,
            capture_output=True, check=True,
        ).stdout.strip()

    def audit(self, sha=None, **env):
        return subprocess.run(
            ["bash", "scripts/audit-source.sh", sha or self.candidate],
            cwd=self.repo, env=dict(self.env, **env), text=True, capture_output=True,
        )

    def assert_audited(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        steps = self.log.read_text().splitlines()
        for required in ("test_source_audit.py", "test_deployment_state.py", "test_delivery.py", "test_queue_measurements.py", "test.sh", "test-dev-lanes.sh", "test-dispatch-tmux.sh", "test-past-agents-search.sh", "test-credits-onboarding.sh"):
            self.assertIn(required, steps)
        self.assertIn("swift build", steps)
        self.assertIn("source audit passed for", result.stdout)

    def test_detached_candidate_is_audited_without_a_remote(self):
        self.git("checkout", "-q", "--detach", self.candidate)
        self.assert_audited(self.audit())

    def test_empty_diff_still_builds_and_tests(self):
        self.git("update-ref", "refs/remotes/origin/main", self.candidate)
        self.assert_audited(self.audit())

    def test_main_advancing_during_audit_does_not_invalidate_candidate(self):
        self.assert_audited(self.audit(AUDIT_TEST_MUTATE="main", AUDIT_TEST_OTHER=self.other))
        self.assertEqual(self.git("rev-parse", "origin/main"), self.other)

    def test_local_main_drift_is_not_a_ci_gate(self):
        self.git("update-ref", "refs/heads/main", self.other)
        self.assert_audited(self.audit())

    def test_wrong_or_nonimmutable_commit_is_rejected_before_build(self):
        for sha in (self.base, "HEAD", self.candidate[:8]):
            with self.subTest(sha=sha):
                self.assertNotEqual(self.audit(sha).returncode, 0)
                self.assertFalse(self.log.exists())

    def test_dirty_checkout_is_rejected_before_build(self):
        (self.repo / "Sources/fixture.swift").write_text("// uncommitted\n")
        self.assertNotEqual(self.audit().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_real_test_failure_cannot_produce_success(self):
        result = self.audit(AUDIT_TEST_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deliberately failing test fixture", result.stderr)
        self.assertNotIn("source audit passed for", result.stdout)

    def test_checkout_changes_during_audit_cannot_produce_success(self):
        for change in ("head", "dirty"):
            with self.subTest(change=change):
                self.git("checkout", "-q", "--detach", self.candidate)
                result = self.audit(AUDIT_TEST_MUTATE=change, AUDIT_TEST_OTHER=self.other)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("source audit passed for", result.stdout)
                self.git("reset", "--hard", self.candidate)

    def test_local_preflight_still_rejects_a_behind_branch(self):
        remote = self.root / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], env=self.env, check=True)
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "origin", self.other + ":refs/heads/main")
        result = subprocess.run(
            ["bash", "scripts/preflight.sh"], cwd=self.repo, env=self.env,
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("behind origin/main", result.stderr)
        self.assertFalse(self.log.exists())

    def test_release_recovery_audits_current_and_historical_targets(self):
        # Execute the actual workflow's source-gate block. Historical commits
        # carry preflight.sh but cannot contain today's audit-source.sh.
        workflow = (SOURCE / ".github/workflows/release-every-merge.yml").read_text()
        gate = workflow.split('          [[ "$TARGET_COMMIT"', 1)[1]
        gate = '[[ "$TARGET_COMMIT"' + gate.split('          scripts/prepare-release-app.sh', 1)[0]
        for historical in (False, True):
            with self.subTest(historical=historical):
                if historical:
                    (self.repo / "scripts/audit-source.sh").unlink()
                    (self.repo / "scripts/preflight.sh").write_text('''#!/bin/bash
set -eu
test "$(git rev-parse --abbrev-ref HEAD)" != HEAD
test "$(git rev-parse "$1")" = "$(git rev-parse HEAD^)"
scripts/test.sh
''')
                    self.git("add", "scripts")
                    self.git("commit", "-qm", "historical gate fixture")
                target = self.git("rev-parse", "HEAD")
                self.git("checkout", "-q", "--detach", target)
                for fail in ("0", "1"):
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", gate], cwd=self.repo,
                        env=dict(self.env, TARGET_COMMIT=target, AUDIT_TEST_FAIL=fail),
                        text=True, capture_output=True,
                    )
                    if fail == "0":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.git("rev-parse", "HEAD"), target)


if __name__ == "__main__":
    unittest.main(verbosity=2)
