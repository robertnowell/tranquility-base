#!/usr/bin/env python3
"""Every compatibility shim carries a dated removal comment.

Rule 3 of docs/rulings/ruling-the-provider-seam.md, adopted verbatim from
Paseo's `docs/protocol-compatibility.md`, whose own docs call grepping for
`COMPAT(` "the full cleanup backlog".

    // COMPAT(name): added in vX, remove after 2027-03-01

It is the only debt-tracking system in the whole provider research that
visibly worked, and it works for one reason: the date is machine-readable,
so the debt expires on its own instead of waiting for somebody to notice it.
A marker with no date is a TODO wearing a uniform.

So this refuses three things, and the third is the point:

  1. a COMPAT marker with no name          -- unattributable
  2. a COMPAT marker with no parseable date -- never expires
  3. a COMPAT marker whose date has PASSED  -- expired, delete the shim

(3) is what makes the other two worth having. A check that only validates
the form would let every shim sit forever in perfect syntax.

`COMPAT(` appeared zero times in the tree when this landed (13 Sep 2026), so
there is no grandfathered backlog and the check is strict from its first
commit.
"""
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The marker, its name, and whatever follows on the same line.
MARKER = re.compile(r"COMPAT\(([^)]*)\)\s*:?(.*)")
# ISO first because it sorts and cannot be read two ways. `remove after` is
# the phrase the ruling prints, but the date is what is actually required --
# a check that insisted on the exact sentence would fail a correct comment
# for its wording.
DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")

# Everything a human wrote. Docs included: the ruling itself carries the
# literal form, and a shim documented in prose and never written in code is
# the same debt. The ruling and this script are exempt -- they are ABOUT the
# marker, so their examples are not shims. Naming them explicitly beats a
# clever pattern that would also exempt a real file one day.
EXEMPT = {"docs/rulings/ruling-the-provider-seam.md", "scripts/check-compat-comments.sh"}
GLOBS = ("Sources/**/*.swift", "Tests/**/*.swift", "scripts/**/*.sh", "docs/**/*.md")

today = datetime.date.today()
bad = []
seen = 0

for glob in GLOBS:
    for path in sorted(ROOT.glob(glob)):
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXEMPT:
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            match = MARKER.search(line)
            if not match:
                continue
            seen += 1
            name, rest = match.group(1).strip(), match.group(2)
            if not name:
                bad.append((rel, n, "COMPAT marker has no name", line.strip()))
                continue
            found = DATE.search(rest)
            if not found:
                bad.append((rel, n, f"COMPAT({name}) has no removal date (YYYY-MM-DD)",
                            line.strip()))
                continue
            try:
                due = datetime.date(*(int(g) for g in found.groups()))
            except ValueError:
                bad.append((rel, n, f"COMPAT({name}) has an impossible date {found.group(0)}",
                            line.strip()))
                continue
            if due < today:
                bad.append((rel, n,
                            f"COMPAT({name}) expired {found.group(0)} -- delete the shim "
                            f"or move the date deliberately",
                            line.strip()))

for rel, n, why, text in bad:
    print(f"{rel}:{n}: {why}\n    {text[:100]}")

if bad:
    print(f"\n{len(bad)} COMPAT problem(s) in {seen} marker(s)")
    sys.exit(1)
print(f"compat comments: clean ({seen} marker(s))")
