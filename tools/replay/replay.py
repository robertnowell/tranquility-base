#!/usr/bin/env python3
"""Re-run corpus records through a candidate prompt via `claude -p` headless.

The prompt template is a plain text file (tools/replay/prompts/<name>.txt)
containing the ENTIRE prompt (system + user scaffolding merged — `claude -p`
takes one prompt). Variable slots are literal tokens substituted with
str.replace (NOT str.format, so the JSON braces in the prompt are safe):

  {project_label}          e.g. "promotions"
  {branch_block}           "\\nBranch: <branch>" or "" — includes its own newline
  {notification_block}     "\\n\\nTHIS SESSION IS BLOCKED..." or ""
  {opening_block}          "\\n\\nHow this session opened, HOURS AGO...:\\n<ask>" or ""
  {last_assistant_message} the agent's final message this turn

Convenience slots (bare values, no scaffolding — for prompts that phrase the
context their own way):

  {branch}                 branch name or ""
  {opening_ask}            the session's opening ask or ""

These mirror exactly what AnthropicSummaryProvider.brief() interpolates in
Sources/VoiceDispatchCore/Summarizer.swift.

Outputs land in tools/replay/runs/<prompt-name>/<record-id>.txt (raw model
reply). Failures/timeouts land in <record-id>.error. Existing outputs are
skipped, so a run is resumable.

Usage:
  python3 replay.py --prompt prompts/current.txt --limit 3
  python3 replay.py --prompt prompts/v2.txt --sample 25 --seed 7 --model haiku
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CORPUS = os.path.join(HERE, "corpus.jsonl")
EMPTY_MCP = os.path.join(HERE, ".empty-mcp.json")


def child_env():
    """A scrubbed environment for the claude subprocess.

    When this harness runs nested inside a Claude Code session (agent-driven
    runs always do), the child CLI inherits CLAUDE*/ANTHROPIC* session vars and
    hangs on startup (observed: every call times out at the limit; with these
    scrubbed the same call answers in ~5s). Scrub them unconditionally."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CLAUDE") or k.startswith("ANTHROPIC"))}
    return env

SLOTS = ("project_label", "branch_block", "notification_block",
         "opening_block", "last_assistant_message", "branch", "opening_ask")


def fill(template, rec):
    out = template
    for slot in SLOTS:
        out = out.replace("{%s}" % slot, rec.get(slot) or "")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--prompt", required=True,
                    help="path to prompt template, e.g. prompts/current.txt")
    ap.add_argument("--corpus", default=DEFAULT_CORPUS)
    ap.add_argument("--model", default="haiku",
                    help="claude -p model (haiku|sonnet|full model id); default haiku")
    ap.add_argument("--limit", type=int, default=None,
                    help="first N records (after --sample, if both given)")
    ap.add_argument("--sample", type=int, default=None,
                    help="random sample of N records")
    ap.add_argument("--seed", type=int, default=42, help="sample seed")
    ap.add_argument("--timeout", type=int, default=240,
                    help="per-call timeout seconds (default 240)")
    ap.add_argument("--workers", type=int, default=4,
                    help="concurrent claude calls (default 4)")
    ap.add_argument("--ids", nargs="*", default=None,
                    help="explicit record ids, e.g. r0001 r0042")
    args = ap.parse_args()

    prompt_path = args.prompt if os.path.isabs(args.prompt) \
        else os.path.join(HERE, args.prompt)
    with open(prompt_path, encoding="utf-8") as f:
        template = f.read()
    name = os.path.splitext(os.path.basename(prompt_path))[0]
    outdir = os.path.join(HERE, "runs", name)
    os.makedirs(outdir, exist_ok=True)

    records = [json.loads(l) for l in open(args.corpus, encoding="utf-8") if l.strip()]
    if args.ids:
        wanted = set(args.ids)
        records = [r for r in records if r["id"] in wanted]
    if args.sample:
        rng = random.Random(args.seed)
        records = rng.sample(records, min(args.sample, len(records)))
        records.sort(key=lambda r: r["id"])
    if args.limit:
        records = records[:args.limit]

    print("replaying %d record(s) with prompt=%s model=%s -> %s"
          % (len(records), name, args.model, outdir))

    def run_one(rec):
        out_path = os.path.join(outdir, rec["id"] + ".txt")
        if os.path.exists(out_path):
            return (rec["id"], "skipped", 0.0)
        prompt = fill(template, rec)
        cmd = ["claude", "-p", "--model", args.model,
               "--dangerously-skip-permissions",
               "--strict-mcp-config", "--mcp-config", EMPTY_MCP]
        t0 = time.time()
        try:
            proc = subprocess.run(
                cmd, input=prompt, capture_output=True, text=True,
                timeout=args.timeout, cwd=HERE, env=child_env())
        except subprocess.TimeoutExpired:
            with open(os.path.join(outdir, rec["id"] + ".error"), "w") as f:
                f.write("timeout after %ds\n" % args.timeout)
            return (rec["id"], "timeout", time.time() - t0)
        elapsed = time.time() - t0
        if proc.returncode != 0 or not proc.stdout.strip():
            with open(os.path.join(outdir, rec["id"] + ".error"), "w") as f:
                f.write("exit=%d\nstderr:\n%s\nstdout:\n%s"
                        % (proc.returncode, proc.stderr, proc.stdout))
            return (rec["id"], "failed", elapsed)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(proc.stdout.strip() + "\n")
        return (rec["id"], "ok", elapsed)

    done = skipped = failed = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(run_one, rec) for rec in records]
        for fut in as_completed(futures):
            rid, status, elapsed = fut.result()
            if status == "ok":
                done += 1
                print("  %s ok (%.1fs)" % (rid, elapsed), flush=True)
            elif status == "skipped":
                skipped += 1
            else:
                failed += 1
                print("  %s %s (%.1fs)" % (rid, status.upper(), elapsed), flush=True)

    print("done=%d skipped(existing)=%d failed=%d" % (done, skipped, failed))
    return 1 if (failed and not done) else 0


if __name__ == "__main__":
    sys.exit(main())
