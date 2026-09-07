#!/usr/bin/env python3
"""Rename every agent hub directory from its first eight characters to the
full session id, and leave a symlink at the old name.

WHY. Hub directories were keyed by the first eight characters of the session id
(15 Aug to 06 Sep). Codex ids are UUIDv7, time-ordered, so two threads started
within about 65 seconds share those characters: 249 threads on 116 prefixes in
Codex's own database, and one directory (01a06cf1) holding two sessions' pages.
The app, the hooks, and the index now name a directory by the full id; this
moves what is already on disk to match, once.

HOW THE FULL ID IS KNOWN. Every hub the app wrote carries its own full id in
the Discuss button (`tranquilitybase://discuss?session=<id>`), and so does
every page the hook stamped. That is the record; it is read before anything
is guessed. Where the pages in one directory name two different sessions and
both are on record (a transcript, a Codex thread, a stored event), the
directory is split: each page goes to the directory of the session that made
it, the hub stays with the session it names, and the symlink at the old name
points at the hub's session. A footer id that is on no record at all (one page
carried a placeholder from a drill) stays with the directory's owner.

SAFE TO RUN WHILE THE OLD APP IS STILL UP. The symlink means an app that still
writes to the eight-character path writes through into the new directory.

    python3 tools/migrate-hub-dirs.py --dry-run     # say what would happen
    python3 tools/migrate-hub-dirs.py               # do it, and write the ledger
"""
import glob
import json
import os
import re
import sqlite3
import sys
from collections import Counter

HOME = os.path.expanduser("~")
AGENTS = os.path.join(HOME, "Documents", "agents")
LEDGER = os.path.join(HOME, "Library", "Application Support", "VoiceDispatch",
                      "hub-migration.log")
SHORT = re.compile(r"^[0-9a-f]{8}$")
FULL = re.compile(r"^[0-9a-f]{8}-[0-9a-f-]{27}$")
DISCUSS = re.compile(r"tranquilitybase://discuss\?session=([0-9a-fA-F-]{36})")


def on_record():
    """Every full session id any harness or store on this machine knows."""
    ids = set()
    for f in glob.glob(f"{HOME}/.claude/projects/*/*.jsonl"):
        ids.add(os.path.basename(f)[:-6].lower())
    for db in glob.glob(f"{HOME}/.codex/state_*.sqlite"):
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            ids.update(i.lower() for (i,) in con.execute("select id from threads"))
        except sqlite3.Error:
            pass
    q = os.path.join(HOME, "Library", "Application Support", "VoiceDispatch", "queue.sqlite")
    try:
        con = sqlite3.connect(f"file:{q}?mode=ro", uri=True)
        ids.update(i.lower() for (i,) in con.execute("select distinct sessionId from events") if i)
    except sqlite3.Error:
        pass
    for f in glob.glob(f"{HOME}/.claude/sessions/*"):
        m = re.search(r"([0-9a-f-]{36})", os.path.basename(f))
        if m:
            ids.add(m.group(1).lower())
    return {i for i in ids if FULL.match(i)}


def footer_ids(path):
    try:
        with open(path, errors="ignore") as fh:
            return {m.lower() for m in DISCUSS.findall(fh.read())}
    except OSError:
        return set()


def pages_of(d):
    out = [p for p in glob.glob(os.path.join(d, "*.html")) if os.path.basename(p) != "index.html"]
    out += glob.glob(os.path.join(d, "*", "index.html"))
    return out


def plan(known):
    """A list of (action, src, dst) for every eight-character real directory."""
    acts = []
    for name in sorted(os.listdir(AGENTS)):
        d = os.path.join(AGENTS, name)
        if not SHORT.match(name) or os.path.islink(d) or not os.path.isdir(d):
            continue
        hub = os.path.join(d, "index.html")
        hub_ids = {i for i in footer_ids(hub) if i.startswith(name)}
        page_ids = {}
        for p in pages_of(d):
            ids = {i for i in footer_ids(p) if i.startswith(name)}
            page_ids[p] = ids
        everything = Counter(i for ids in page_ids.values() for i in ids)
        # The owner: the hub's own id; else the one id on record with this prefix;
        # else the id the pages name most often.
        candidates = sorted(i for i in known if i.startswith(name))
        if len(hub_ids) == 1:
            owner = next(iter(hub_ids))
        elif len(candidates) == 1:
            owner = candidates[0]
        elif everything:
            owner = everything.most_common(1)[0][0]
        else:
            acts.append(("unresolved", d, ""))
            continue
        acts.append(("rename", d, os.path.join(AGENTS, owner)))
        acts.append(("symlink", d, owner))
        for p, ids in sorted(page_ids.items()):
            others = {i for i in ids if i != owner and i in known}
            if len(others) == 1 and owner not in ids:
                other = next(iter(others))
                rel = os.path.relpath(p, d)
                acts.append(("split", os.path.join(AGENTS, owner, rel),
                             os.path.join(AGENTS, other, rel)))
    return acts


def apply(acts, dry):
    done, renamed = [], set()
    for action, src, dst in acts:
        if action == "rename":
            if os.path.exists(dst):
                done.append(("skip-exists", src, dst)); continue
            if not dry:
                os.rename(src, dst)
            renamed.add(src)
        elif action == "symlink":
            # After the rename nothing is at the old name; in a dry run the
            # directory is still there, and that is the rename's, not a clash.
            if src not in renamed and os.path.lexists(src):
                done.append(("skip-symlink", src, dst)); continue
            if not dry:
                os.symlink(dst, src)
        elif action == "split":
            if os.path.exists(dst):
                done.append(("skip-exists", src, dst)); continue
            if not dry:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.rename(src, dst)
        done.append((action, src, dst))
    return done


def main():
    dry = "--dry-run" in sys.argv
    known = on_record()
    acts = plan(known)
    done = apply(acts, dry)
    counts = Counter(a for a, _, _ in done)
    for a, s, d in done:
        if a in ("split", "unresolved", "skip-exists", "skip-symlink"):
            print(f"{a}\t{s}\t{d}")
    print(("would do: " if dry else "did: ") + json.dumps(counts))
    if not dry:
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        with open(LEDGER, "a") as fh:
            for a, s, d in done:
                fh.write(f"{a}\t{s}\t{d}\n")
        print(f"ledger: {LEDGER}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
