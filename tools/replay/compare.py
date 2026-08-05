#!/usr/bin/env python3
"""Side-by-side comparison of two output sets over the replay corpus.

Each side is either the name of a run directory under tools/replay/runs/
(e.g. "current", "v2-callsign") or the literal "actual" — the historical
production output stored in corpus.jsonl.

For every record present on both sides the report shows the source event
snippet, both spoken outputs, word counts, and three mechanical flags that
preview the tuning rubric:

  DIGITS?   speaks a number absent from the source (digit-grounding check)
  CALLSIGN  opens with the session name (project label / topic first)
  ASKS?     ends with a question mark (request typing check)

Output: tools/replay/reports/<a>-vs-<b>.md

Usage:
  python3 compare.py current actual
  python3 compare.py v2 current --limit 20
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CORPUS = os.path.join(HERE, "corpus.jsonl")

NUMBER_WORDS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
    "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
    "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
    "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
}


def parse_brief(text):
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


def spoken_text(raw_output, project_label):
    """Spoken line for an output: SessionBrief.spokenText() if the output is
    brief-JSON, otherwise the raw text itself (a rewritten prompt may emit a
    bare spoken line rather than JSON)."""
    brief = parse_brief(raw_output)
    if brief is None:
        return (raw_output or "").strip()
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


def numbers_in(text):
    """All numeric values mentioned, as canonical digit strings."""
    found = set(re.findall(r"\d+(?:\.\d+)?", text or ""))
    for w, d in NUMBER_WORDS.items():
        if re.search(r"\b%s\b" % w, text or "", re.IGNORECASE):
            found.add(d)
    return found


def flag_digits(spoken, source):
    """Numbers spoken that appear nowhere in the source material."""
    src = numbers_in(source)
    # Also accept digit-substrings: "12" grounded if source says "129" is NOT ok,
    # but "2023" in a URL should ground "2023". Exact-match only, plus the
    # source's raw text as a fallback for decimals embedded in versions.
    ungrounded = {n for n in numbers_in(spoken)
                  if n not in src and n not in (source or "")}
    return sorted(ungrounded)


def flag_callsign(spoken, project_label, topic):
    """Does the spoken line open with the session's name?"""
    def norm(s):
        return re.sub(r"[^a-z0-9 ]", " ", (s or "").lower()).split()
    head = norm(spoken)[:6]
    for name in (project_label, topic):
        toks = norm(name)
        if toks and all(t in head for t in toks[:2]):
            return True
    return False


def flag_question(spoken):
    return (spoken or "").rstrip().rstrip('"”’').endswith("?")


def load_side(name, records):
    """Return {record_id: raw_output} for a run dir or the corpus actuals."""
    if name == "actual":
        return {r["id"]: r["actual_output"] for r in records}
    rundir = os.path.join(HERE, "runs", name)
    if not os.path.isdir(rundir):
        sys.exit("no such run directory: %s" % rundir)
    out = {}
    for fn in os.listdir(rundir):
        if fn.endswith(".txt"):
            with open(os.path.join(rundir, fn), encoding="utf-8") as f:
                out[fn[:-4]] = f.read().strip()
    return out


def wc(text):
    return len((text or "").split())


def snippet(text, n=280):
    t = " ".join((text or "").split())
    return t[:n] + ("…" if len(t) > n else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a", help="run name under runs/, or 'actual'")
    ap.add_argument("b", help="run name under runs/, or 'actual'")
    ap.add_argument("--corpus", default=DEFAULT_CORPUS)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--out", default=None,
                    help="report path (default reports/<a>-vs-<b>.md)")
    args = ap.parse_args()

    records = [json.loads(l) for l in open(args.corpus, encoding="utf-8") if l.strip()]
    by_id = {r["id"]: r for r in records}
    side_a, side_b = load_side(args.a, records), load_side(args.b, records)

    ids = sorted(set(side_a) & set(side_b) & set(by_id))
    if args.limit:
        ids = ids[:args.limit]
    if not ids:
        sys.exit("no overlapping record ids between %s and %s" % (args.a, args.b))

    out_path = args.out or os.path.join(HERE, "reports", "%s-vs-%s.md" % (args.a, args.b))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    totals = {s: {"words": 0, "digits": 0, "callsign": 0, "asks": 0} for s in "ab"}
    lines = ["# %s vs %s" % (args.a, args.b), "",
             "%d record(s) compared. Flags: DIGITS? = speaks a number absent "
             "from the source; CALLSIGN = opens with the session name; "
             "ASKS? = ends with a question." % len(ids), ""]

    body = []
    for rid in ids:
        rec = by_id[rid]
        source = (rec.get("last_assistant_message") or "") + "\n" + \
                 (rec.get("opening_ask") or "") + "\n" + \
                 (rec.get("branch") or "") + "\n" + rec.get("project_label", "")
        row = {}
        for side, raw in (("a", side_a[rid]), ("b", side_b[rid])):
            brief = parse_brief(raw)
            spoken = spoken_text(raw, rec["project_label"])
            topic = (brief or {}).get("topic")
            digits = flag_digits(spoken, source)
            cs = flag_callsign(spoken, rec["project_label"], topic)
            asks = flag_question(spoken)
            row[side] = (spoken, digits, cs, asks)
            totals[side]["words"] += wc(spoken)
            totals[side]["digits"] += bool(digits)
            totals[side]["callsign"] += cs
            totals[side]["asks"] += asks

        body += ["## %s — %s (%s)" % (rid, rec["project_label"], rec.get("at", "?")), "",
                 "**Source (agent's final message):** %s" % snippet(rec["last_assistant_message"]), ""]
        for side, name in (("a", args.a), ("b", args.b)):
            spoken, digits, cs, asks = row[side]
            flags = []
            if digits:
                flags.append("DIGITS? (%s)" % ", ".join(digits))
            flags.append("CALLSIGN" if cs else "no-callsign")
            flags.append("ASKS?" if asks else "no-question")
            body += ["**%s** (%d words) — %s" % (name, wc(spoken), ", ".join(flags)),
                     "", "> %s" % (spoken or "(empty)").replace("\n", " "), ""]
        body.append("---")
        body.append("")

    n = len(ids)
    lines += ["| | %s | %s |" % (args.a, args.b),
              "|---|---|---|",
              "| avg words spoken | %.1f | %.1f |" % (totals["a"]["words"] / n, totals["b"]["words"] / n),
              "| ungrounded-number records | %d/%d | %d/%d |" % (totals["a"]["digits"], n, totals["b"]["digits"], n),
              "| opens with callsign | %d/%d | %d/%d |" % (totals["a"]["callsign"], n, totals["b"]["callsign"], n),
              "| ends with question | %d/%d | %d/%d |" % (totals["a"]["asks"], n, totals["b"]["asks"], n),
              "", ""] + body

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("wrote %s (%d records)" % (out_path, n))


if __name__ == "__main__":
    sys.exit(main())
