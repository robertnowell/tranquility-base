#!/usr/bin/env python3
"""Does a continued agent actually reach the part of the log it was not given?

Continue with pastes the end of the old log and names three hq-log commands
for the rest. This asks a real, headless agent questions whose answers are
ONLY in the part that was not pasted, and passes a case when the agent both
ran hq-log and gave the answer. It costs model calls, so it is run by hand,
never by CI.

    scripts/handoff-retrieval-check.py cases.json [--dest claude|codex] [--tokens N]

cases.json: {"session": id, "harness": "codex"|"claude-code", "log": path,
             "cases": [{"ask": question, "expect": regex}]}

Both sides are asserted: a case whose answer is already in the pasted part is
refused as a bad case, because it would pass without any retrieval.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "skills", "bin")


def option(argv, name, default):
    if name in argv:
        i = argv.index(name)
        value = argv[i + 1]
        del argv[i:i + 2]
        return value
    return default


def run_claude(prompt, env, cwd):
    out = subprocess.run(
        ["claude", "-p", "--output-format", "stream-json", "--verbose",
         "--allowedTools", "Bash(hq-log:*)"],
        input=prompt, capture_output=True, text=True, env=env, cwd=cwd, timeout=900)
    commands, answer = [], ""
    for line in out.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("type") == "assistant":
            for block in (row.get("message") or {}).get("content") or []:
                if block.get("type") == "tool_use":
                    commands.append(str((block.get("input") or {}).get("command", "")))
        if row.get("type") == "result":
            answer = str(row.get("result") or "")
    return commands, answer


def run_codex(prompt, env, cwd):
    out = subprocess.run(
        ["codex", "exec", "--json", "--skip-git-repo-check", "-"],
        input=prompt, capture_output=True, text=True, env=env, cwd=cwd, timeout=900)
    commands, answer = [], ""
    for line in out.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        item = row.get("item") or {}
        if item.get("type") == "command_execution" and row.get("type") == "item.completed":
            commands.append(str(item.get("command", "")))
        if item.get("type") == "agent_message" and row.get("type") == "item.completed":
            answer = str(item.get("text") or "")
    if not answer and out.returncode != 0:
        answer = "(codex exec failed: %s)" % out.stderr.strip()[-300:]
    return commands, answer


def main(argv):
    dest = option(argv, "--dest", "claude")
    tokens = option(argv, "--tokens", "50000")
    if not argv:
        print(__doc__.strip())
        return 2
    spec = json.load(open(argv[0]))
    env = dict(os.environ, PATH=BIN + os.pathsep + os.environ.get("PATH", ""))
    tbase = os.path.join(ROOT, ".build", "debug", "tbase")
    fragment = subprocess.run(
        [tbase, "handoff-text", spec["session"], spec["harness"], spec["log"],
         "--tokens", tokens, "--hq-log", os.path.join(BIN, "hq-log")],
        capture_output=True, text=True, check=True).stdout.rstrip("\n")
    print("first message: %d characters, destination %s" % (len(fragment), dest))
    runner = run_codex if dest == "codex" else run_claude
    failed = 0
    with tempfile.TemporaryDirectory(prefix="handoff-check-") as cwd:
        for case in spec["cases"]:
            if re.search(case["expect"], fragment, re.I):
                print("BAD CASE  the answer is already in the pasted part: %s" % case["ask"])
                failed += 1
                continue
            commands, answer = runner(fragment + "\n\n" + case["ask"], env, cwd)
            used = [c for c in commands if "hq-log" in c]
            right = re.search(case["expect"], answer, re.I) is not None
            ok = bool(used) and right
            failed += 0 if ok else 1
            print("%s  searched=%d answered=%s  %s" % (
                "PASS" if ok else "FAIL", len(used), "yes" if right else "no", case["ask"]))
            for c in used[:6]:
                print("        $ " + " ".join(c.split())[:150])
            print("        > " + " ".join(answer.split())[:260])
    print("%d of %d cases passed" % (len(spec["cases"]) - failed, len(spec["cases"])))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
