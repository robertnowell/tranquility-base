#!/usr/bin/env python3
"""Extract the summarizer's historical inputs+outputs into a replay corpus.

Source: ~/Library/Application Support/VoiceDispatch/model-calls.jsonl
(written by Sources/TranquilityCore/ModelCallLog.swift; one line per
Anthropic call made by AnthropicSummaryProvider in Summarizer.swift).

Each JSONL line has: {at, model, status, elapsedMs, system, user, response}.
The `user` field is the assembled user-turn content:

    Project: <label>
    [\n\nTHIS SESSION IS BLOCKED AND WAITING ON THE USER (<matcher>)...]   (notification only)
    [\nBranch: <branch>]
    [\n\nHow this session opened, HOURS AGO and possibly abandoned since. ...:\n<ask>]

    The agent's final message this turn:
    <lastAssistantMessage>

This script parses that back into the fields Summarizer.swift interpolates,
so replay.py can re-substitute them into a candidate prompt template.

Output: one JSON object per line in corpus.jsonl:
  id, at, model, elapsed_ms,
  project_label, branch, notification_block, opening_ask, opening_block,
  branch_block, last_assistant_message,
  raw_user            (exactly what the model received as the user turn),
  raw_system          (exactly what the model received as the system prompt),
  actual_output       (the model's raw text reply),
  actual_brief        (parsed JSON fields, or null),
  actual_spoken       (recap+proposal, or assembled fallback — mirrors
                       SessionBrief.spokenText()),
  roundtrip_ok        (true if rebuilding the user turn from parsed fields
                       reproduces raw_user byte-for-byte)

Usage:
  python3 extract.py [--log PATH] [--out PATH]
"""

import argparse
import json
import os
import sys

DEFAULT_LOG = os.path.expanduser(
    "~/Library/Application Support/VoiceDispatch/model-calls.jsonl")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "corpus.jsonl")

FINAL_MSG_MARKER = "\n\nThe agent's final message this turn:\n"
OPENING_MARKER = "\n\nHow this session opened, HOURS AGO"
NOTIF_MARKER = "\n\nTHIS SESSION IS BLOCKED AND WAITING ON THE USER"


def parse_user(raw_user):
    """Split the assembled user turn back into its source fields."""
    if FINAL_MSG_MARKER not in raw_user:
        return None
    context, last_msg = raw_user.split(FINAL_MSG_MARKER, 1)

    opening_block = ""
    opening_ask = None
    if OPENING_MARKER in context:
        idx = context.index(OPENING_MARKER)
        opening_block = context[idx:]
        context = context[:idx]
        # The ask is everything after the instruction paragraph's trailing ":\n"
        colon = opening_block.find(":\n")
        if colon != -1:
            opening_ask = opening_block[colon + 2:]

    notification_block = ""
    if NOTIF_MARKER in context:
        idx = context.index(NOTIF_MARKER)
        # Block runs until the Branch line (if any) or end of context.
        rest = context[idx:]
        b = rest.find("\nBranch: ")
        if b != -1:
            notification_block = rest[:b]
            context = context[:idx] + rest[b:]
        else:
            notification_block = rest
            context = context[:idx]

    branch = None
    branch_block = ""
    if "\nBranch: " in context:
        idx = context.index("\nBranch: ")
        branch_block = context[idx:]
        branch = branch_block[len("\nBranch: "):].split("\n", 1)[0]
        context = context[:idx]

    if not context.startswith("Project: "):
        return None
    project_label = context[len("Project: "):].split("\n", 1)[0]

    return {
        "project_label": project_label,
        "branch": branch,
        "branch_block": branch_block,
        "notification_block": notification_block,
        "opening_ask": opening_ask,
        "opening_block": opening_block,
        "last_assistant_message": last_msg,
    }


def rebuild_user(f):
    """Rebuild the user turn from parsed fields (the current Swift assembly order)."""
    return ("Project: " + f["project_label"]
            + f["notification_block"] + f["branch_block"] + f["opening_block"]
            + FINAL_MSG_MARKER + f["last_assistant_message"])


def extract_output_text(response_raw):
    """Pull the model's text out of the logged Anthropic response body."""
    try:
        r = json.loads(response_raw)
    except (ValueError, TypeError):
        return None
    content = r.get("content")
    if not isinstance(content, list):
        return None
    text = "".join(c.get("text", "") for c in content
                   if isinstance(c, dict) and c.get("type") == "text")
    return text.strip() or None


def parse_brief(text):
    """Mirror AnthropicSummaryProvider.parse: find outermost {...}, tolerate fences."""
    if not text:
        return None
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    try:
        obj = json.loads(text[start:end + 1])
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None

    def field(k):
        v = obj.get(k)
        if not isinstance(v, str):
            return None
        v = v.strip()
        return None if (not v or v.lower() == "null") else v

    return {k: field(k) for k in
            ("recap", "proposal", "topic", "goal", "happened",
             "nextStep", "question", "risk")}


def spoken_text(brief, project_label):
    """Mirror SessionBrief.spokenText()."""
    if brief is None:
        return None
    if brief.get("recap"):
        out = brief["recap"]
        if brief.get("proposal"):
            out += " " + brief["proposal"]
        return out
    parts = [(brief.get("topic") or project_label) + "."]
    happened = brief.get("happened") or ""
    if happened:
        parts.append(happened if happened.endswith(".") else happened + ".")
    if brief.get("question"):
        parts.append(brief["question"])
    elif brief.get("nextStep"):
        ns = brief["nextStep"]
        parts.append(ns if ns.endswith(".") else ns + ".")
    return " ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    total = skipped_status = skipped_parse = roundtrip_fail = 0
    records = []
    with open(args.log, encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            total += 1
            entry = json.loads(line)
            if entry.get("status") != 200:
                skipped_status += 1
                continue
            fields = parse_user(entry.get("user", ""))
            output = extract_output_text(entry.get("response", ""))
            if fields is None or output is None:
                skipped_parse += 1
                continue
            brief = parse_brief(output)
            rec = {
                "id": "r%04d" % i,
                "at": entry.get("at"),
                "model": entry.get("model"),
                "elapsed_ms": entry.get("elapsedMs"),
                **fields,
                "raw_user": entry["user"],
                "raw_system": entry.get("system", ""),
                "actual_output": output,
                "actual_brief": brief,
                "actual_spoken": spoken_text(brief, fields["project_label"]),
                "roundtrip_ok": rebuild_user(fields) == entry["user"],
            }
            if not rec["roundtrip_ok"]:
                roundtrip_fail += 1
            records.append(rec)

    with open(args.out, "w", encoding="utf-8") as out:
        for rec in records:
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print("log entries:        %d" % total)
    print("skipped (status):   %d" % skipped_status)
    print("skipped (parse):    %d" % skipped_parse)
    print("usable records:     %d" % len(records))
    print("roundtrip failures: %d  (parsed fields do not rebuild raw_user "
          "byte-for-byte; replay still uses parsed fields)" % roundtrip_fail)
    print("wrote %s" % args.out)


if __name__ == "__main__":
    sys.exit(main())
