#!/usr/bin/env python3
"""What the archive already calls things.

There is no maintained tag list, deliberately. A central vocabulary is a file
somebody has to keep true, and the moment it drifts from the corpus it is worse
than nothing: it tells a writer a term exists that nothing uses, or omits the one
half the archive is about. Ruled 02 Sep.

What replaces it is a standard for the shape of a tag, and this: the tags
already in use, ranked, so reusing one is easier than inventing a synonym. The
list is derived from the catalog on every run, so it cannot be stale, and it
converges on its own because writers can see what to converge on.

    hq-tags              the 40 most used, with counts
    hq-tags --all        every tag in the corpus
    hq-tags send         only tags matching "send"
"""
import json
import os
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hqconfig import roots  # noqa: E402


def tags(catalog=None):
    path = Path(catalog) if catalog else roots.out / "catalog.json"
    try:
        rows = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"hq-tags: cannot read {path}: {e}")
    return Counter(t.strip() for r in rows for t in (r.get("tags") or []) if t.strip())


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    counts = tags(os.environ.get("HQ_CATALOG"))
    if not counts:
        print("no tags in the corpus yet", file=sys.stderr)
        return 1
    needle = args[0].lower() if args else ""
    rows = [(t, n) for t, n in counts.most_common() if needle in t.lower()]
    if not ("--all" in argv or needle):
        rows = rows[:40]
    width = max((len(t) for t, _ in rows), default=10)
    for t, n in rows:
        print(f"{n:5}  {t}")
    if not needle and "--all" not in argv and len(counts) > 40:
        print(f"\n{len(counts) - 40} more; hq-tags --all, or hq-tags <word> to search",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
