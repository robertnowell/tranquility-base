#!/usr/bin/env python3
"""Post-command hook: record observed merge intent; never install from a hook."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "robertnowell/tranquility-base"


def merge_target(command):
    """Recognize literal gh merge invocations without evaluating shell text.

    Return (found, target, repository). Dynamic shell expressions are left for
    the owning session's explicit delivery watch command; never execute them.
    """
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        return False, None, None
    for i in range(len(words) - 2):
        if words[i:i + 3] != ["gh", "pr", "merge"]:
            continue
        target, repository = None, None
        j = i + 3
        while j < len(words) and not any(c in words[j] for c in ";&|()\n"):
            word = words[j]
            if word in ("--repo", "-R"):
                j += 1
                if j < len(words):
                    repository = words[j]
            elif word.startswith("--repo="):
                repository = word.split("=", 1)[1]
            elif word in ("--body", "-b", "--body-file", "-F", "--subject", "-t", "--match-head-commit"):
                j += 1
            elif not word.startswith("-"):
                target = word
            j += 1
        return True, target, repository
    return False, None, None


def resolve_pr(target, repository, cwd, run=subprocess.run):
    if repository and repository != REPOSITORY:
        return None
    match = re.fullmatch(r"https://github\.com/robertnowell/tranquility-base/pull/([1-9][0-9]*)/?", target or "")
    if match:
        return int(match[1])
    # A bare number is scoped by --repo or by the event's working directory.
    if not repository:
        remote = run(["git", "remote", "get-url", "origin"], cwd=cwd, text=True,
                     capture_output=True, check=True, timeout=10).stdout.strip()
        if remote.removesuffix(".git") not in (f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}"):
            return None
    if target and re.fullmatch(r"[1-9][0-9]*", target):
        return int(target)
    if target:
        raise ValueError("merge target is not a literal PR number or repository URL")
    result = run(["gh", "pr", "view", "--json", "number"], cwd=cwd, text=True,
                 capture_output=True, check=True, timeout=20)
    return int(json.loads(result.stdout)["number"])


def main():
    try:
        event = json.load(sys.stdin)
        found, target, repository = merge_target(event.get("tool_input", {}).get("command", ""))
        if not found:
            return 0
        pr = resolve_pr(target, repository, event.get("cwd") or ROOT)
        if pr is None:
            return 0
        owner = "session-" + str(event.get("session_id") or "manual")
        result = subprocess.run([sys.executable, str(ROOT / "scripts/delivery.py"), "watch",
                                 "--pr", str(pr), "--owner", owner, "--observe-only"], timeout=180)
        print(f"PR {pr}: merge progress recorded. Resume delivery with scripts/delivery.py watch --pr {pr} --owner {owner} --wait")
        return 0 if result.returncode in (0, 75) else result.returncode
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Merge delivery needs its owner: {error}. Run scripts/delivery.py watch --pr NUMBER --owner SESSION --wait.", file=sys.stderr)
        return 0  # Hook failure must not turn a successful merge into a retry.


if __name__ == "__main__":
    sys.exit(main())
