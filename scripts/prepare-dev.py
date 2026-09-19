#!/usr/bin/env python3
"""Prepare a pinned Dev artifact under a build lock, then lease it for activation."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CLEAN = Path("/private/tmp/tb-clean")
CACHE = Path.home() / "Library/Caches/TranquilityBase/prepared-dev"


def command(*args, root=None):
    return subprocess.check_output(args, cwd=root or ROOT, text=True, timeout=60).strip()


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()


def verify(artifact, target):
    metadata = json.loads((artifact / "manifest.json").read_text())
    if metadata.get("version") != 1 or metadata.get("sha") != target:
        raise ValueError("prepared artifact belongs to a different source")
    app = artifact / "Tranquility Base Dev.app"
    with (app / "Contents/Info.plist").open("rb") as source: info = plistlib.load(source)
    if info.get("TBSourceCommit") != target or info.get("TBAppChannel") != "development":
        raise ValueError("prepared app source/channel mismatch")
    for name, expected in metadata["files"].items():
        path = artifact / name
        if path.is_symlink() or not path.is_relative_to(artifact) or ".." in Path(name).parts:
            raise ValueError("invalid prepared artifact path")
        if file_digest(path) != expected: raise ValueError(f"prepared artifact changed: {name}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    return app


def held_build_lock():
    try:
        fd = int(os.environ["TB_BUILD_LOCK_FD"])
        actual, expected = os.fstat(fd), (CACHE / "build.lock").stat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino): return False
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except (KeyError, ValueError, OSError):
        return False


def leased(artifact):
    fd = int(os.environ["TB_ARTIFACT_LEASE_FD"])
    actual, expected = os.fstat(fd), (artifact / "lease.lock").stat()
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        raise ValueError("prepared artifact lease is missing")
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)


def prune(cache, keep):
    # A live app can run directly from an artifact on an uninstalled machine.
    # Never remove its executable, even after the activation lease ended.
    processes = command("ps", "-axo", "comm=")
    for path in cache.glob("artifact-*"):
        if path == keep or path.is_symlink() or time.time() - path.stat().st_mtime < 86400: continue
        if str(path) in processes: continue
        try:
            with (path / "lease.lock").open("r+") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                shutil.rmtree(path)
        except (BlockingIOError, FileNotFoundError):
            continue


def prepare(target):
    CACHE.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (CACHE / "build.lock").open("a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise BlockingIOError("another process is preparing the shared build workspace")
    try:
        # The wrapper is specifically the stable Dev lane, including standalone
        # build-clean calls. Production builds continue through release tooling.
        identity = dict(VD_APP_NAME="Tranquility Base Dev", VD_BUNDLE_ID="com.robertnowell.voice-dispatch.dev",
                        VD_APP_CHANNEL="development", VD_UPDATES_ENABLED="false",
                        VD_URL_SCHEMES="tranquilitybase voicedispatch tbdev",
                        TB_FEED_URL="https://updates.tranquilitybase.to/dev-appcast.xml")
        inputs = {name: os.environ.get(name, "") for name in (
            "TB_ARCHS", "VOICE_DISPATCH_SIGN_IDENTITY", "VD_SIGN_CN", "VD_SIGN_KEYCHAIN")}
        inputs.update(sha=target, configuration="debug", toolchain=command("swift", "--version"),
                      sdk=command("xcrun", "--show-sdk-build-version"))
        key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        artifact = CACHE / ("artifact-" + key)
        if not artifact.exists():
            started = time.monotonic()
            env = dict(os.environ, **identity, TB_BUILD_LOCK_FD=str(lock.fileno()))
            raw = subprocess.check_output([str(ROOT / "scripts/build-clean.sh"), target],
                                          cwd=ROOT, env=env, pass_fds=(lock.fileno(),), text=True).strip()
            raw_app = Path(raw)
            clean = CLEAN
            subprocess.run(["swift", "build", "--configuration", "debug", "--product", "tbase"],
                           cwd=clean, check=True, stdout=sys.stderr, pass_fds=(lock.fileno(),))
            partial = Path(tempfile.mkdtemp(prefix=".partial-", dir=CACHE))
            try:
                shutil.copytree(raw_app, partial / "Tranquility Base Dev.app", symlinks=True)
                archive = partial / "source.tar"
                with archive.open("wb") as out:
                    subprocess.run(["git", "archive", target, "scripts"], cwd=ROOT, stdout=out, check=True)
                with tarfile.open(archive) as source: source.extractall(partial)
                archive.unlink()
                (partial / "bin").mkdir()
                shutil.copy2(clean / ".build/debug/tbase", partial / "bin/tbase")
                files = {str(p.relative_to(partial)): file_digest(p) for base in [partial / "scripts", partial / "bin"]
                         for p in base.rglob("*") if p.is_file()}
                metadata = dict(version=1, sha=target, inputs=inputs, files=files,
                                architectures=command("lipo", "-archs", str(raw_app / "Contents/MacOS/TranquilityApp")),
                                preparation_seconds=round(time.monotonic()-started, 3))
                (partial / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
                (partial / "lease.lock").touch()
                verify(partial, target)
                partial.rename(artifact)
            finally:
                if partial.exists(): shutil.rmtree(partial)
        print(f"→ prepared {target} at {artifact}", file=sys.stderr, flush=True)
        app = verify(artifact, target)
        os.utime(artifact, None)
        lease = (artifact / "lease.lock").open("r+")
        fcntl.flock(lease, fcntl.LOCK_SH)
        prune(CACHE, artifact)
        return artifact, app, lease
    finally:
        lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["build", "relaunch", "verify", "lock-held"])
    parser.add_argument("ref", nargs="?", default="origin/main")
    parser.add_argument("artifact", nargs="?", type=Path)
    args = parser.parse_args()
    if args.operation == "lock-held": return 0 if held_build_lock() else 1
    if args.operation == "verify":
        leased(args.artifact)
        verify(args.artifact, args.ref)
        return 0
    command("git", "fetch", "-q", "origin")
    target = command("git", "rev-parse", "--verify", args.ref + "^{commit}")
    artifact, app, lease = prepare(target)
    try:
        if args.operation == "build":
            print(app)
            return 0
        env = dict(os.environ, TB_ARTIFACT_LEASE_FD=str(lease.fileno()))
        result = subprocess.run([str(ROOT / "scripts/relaunch.sh"), "--activate-prepared", target, str(artifact)],
                                cwd=ROOT, env=env, pass_fds=(lease.fileno(),))
        if result.returncode == 0:
            # Archive health is informational; it cannot extend app ownership or
            # delay a successful receipt. Its pinned tool and lease outlive us.
            log = Path.home() / "Library/Logs/TranquilityBase/delivery-health" / (target + ".log")
            log.parent.mkdir(parents=True, exist_ok=True)
            with (log.parent / (target + ".runner.log")).open("ab") as output:
                subprocess.Popen([sys.executable, str(artifact / "scripts/run-stage.py"), "--timeout", "30",
                                  "--log", str(log), "--", str(artifact / "bin/tbase"), "doctor"],
                                 cwd=artifact, stdout=output, stderr=output, start_new_session=True,
                                 pass_fds=(lease.fileno(),))
        return result.returncode
    finally:
        lease.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BlockingIOError as error:
        print(f"deployment deferred: {error}", file=sys.stderr)
        sys.exit(75)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"prepared build failed: {error}", file=sys.stderr)
        sys.exit(1)
