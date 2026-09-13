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

# The WORD, not the word-plus-paren. `COMPAT(name` with an unclosed paren and
# `COMPAT name:` without one both read as the marker to a person and both
# escaped the first version of this check, which looked for the literal
# "COMPAT(". The ruling's claim is that grepping the marker is the whole
# cleanup backlog, and a marker the checker cannot see is worse than no marker:
# it looks tracked.
MARKER = re.compile(r"\bCOMPAT\b(.*)")
NAMED = re.compile(r"^\(([^)\n]*)\)")
# ANCHORED to "remove after", never just the first date on the line. A shim
# that records when the vendor broke it -- "broken since 2020-01-01, remove
# after 2027-01-01" -- read as expired under the first version, which is the
# failure that makes a checker something people route around.
DUE = re.compile(r"remove\s+after\s+(\d{4})-(\d{2})-(\d{2})")

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
            # Prose ABOUT the marker is not a marker, and the two are
            # genuinely hard to tell apart from the outside: a doc comment
            # explaining the form contains the form. Same escape hatch
            # check-key-names.sh already uses, so an exemption is a decision
            # somebody made rather than a hole in the pattern.
            if "compat:exempt" in line:
                continue
            match = MARKER.search(line)
            if not match:
                continue
            seen += 1
            rest = match.group(1)
            named = NAMED.match(rest)
            if not named:
                bad.append((rel, n, "COMPAT marker is not COMPAT(name): ...", line.strip()))
                continue
            name = named.group(1).strip()
            if not name:
                bad.append((rel, n, "COMPAT marker has no name", line.strip()))
                continue
            found = DUE.search(rest)
            if not found:
                bad.append((rel, n,
                            f"COMPAT({name}) has no 'remove after YYYY-MM-DD'",
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
                            f"COMPAT({name}) expired {due.isoformat()} -- delete the shim "
                            f"or move the date deliberately",
                            line.strip()))

for rel, n, why, text in bad:
    print(f"{rel}:{n}: {why}\n    {text[:100]}")

if bad:
    print(f"\n{len(bad)} COMPAT problem(s) in {seen} marker(s)")
    sys.exit(1)
print(f"compat comments: clean ({seen} marker(s))")
