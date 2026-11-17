#!/usr/bin/env python3
"""Every compatibility shim names itself and says what ends it.

Rule 3 of docs/rulings/ruling-the-provider-seam.md, as amended 16 Nov 2026.

    // COMPAT(name): why it is here, and what ends it

Grepping for the marker is the whole cleanup backlog, and this check keeps the
grep honest. It refuses two things:

  1. a COMPAT marker with no name    -- unattributable
  2. a COMPAT marker with no reason  -- nobody can tell when it may go

**This check never reads the clock.** Its first version (13 Sep 2026) also
refused a marker whose "remove after" date had passed. On 16 Nov 2026 a date
of 2026-11-15 passed, and every pull request to main failed its source audit,
whatever it changed. Three more markers carried 2026-12-01. A verdict that
depends on the day is not a verdict about the commit: the same commit passes
on Sunday and fails on Monday, and the session it stops is never the one that
owes the work. Ruled the same day: nothing in the delivery path may fail
because a date arrived.

What ends a shim is now an event in the tree, and a test watches for it.
`CapabilityLivenessTests` does that for every marker that exists today: a
listed field that becomes live fails the suite, and so does a new dead one. A
date in a marker is allowed as a note and is never read.

    check-compat-comments.sh [--root DIR]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
if "--root" in sys.argv:
    ROOT = pathlib.Path(sys.argv[sys.argv.index("--root") + 1]).resolve()

# The WORD, not the word-plus-paren. `COMPAT(name` with an unclosed paren and
# `COMPAT name:` without one both read as the marker to a person and both
# escaped the first version of this check, which looked for the literal
# "COMPAT(". The ruling's claim is that grepping the marker is the whole
# cleanup backlog, and a marker the checker cannot see is worse than no marker:
# it looks tracked.
MARKER = re.compile(r"\bCOMPAT\b(.*)")
NAMED = re.compile(r"^\(([^)\n]*)\)(.*)")

# Everything a human wrote. Docs included: the ruling itself carries the
# literal form, and a shim documented in prose and never written in code is
# the same debt. The ruling and this script are exempt -- they are ABOUT the
# marker, so their examples are not shims. Naming them explicitly beats a
# clever pattern that would also exempt a real file one day.
EXEMPT = {"docs/rulings/ruling-the-provider-seam.md",
          "docs/rulings/ruling-no-date-fails-the-build.md",
          "scripts/check-compat-comments.sh"}
GLOBS = ("Sources/**/*.swift", "Tests/**/*.swift", "scripts/**/*.sh", "docs/**/*.md")

bad = []
seen = []

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
            named = NAMED.match(match.group(1))
            if not named:
                bad.append((rel, n, "COMPAT marker is not COMPAT(name): ...", line.strip()))
                continue
            name = named.group(1).strip()
            if not name:
                bad.append((rel, n, "COMPAT marker has no name", line.strip()))
                continue
            if not named.group(2).lstrip(": \t").strip():
                bad.append((rel, n, f"COMPAT({name}) does not say what ends it", line.strip()))
                continue
            seen.append((rel, n, name))

for rel, n, why, text in bad:
    print(f"{rel}:{n}: {why}\n    {text[:100]}")

if bad:
    print(f"\n{len(bad)} COMPAT problem(s), {len(seen)} well-formed marker(s)")
    sys.exit(1)
# The backlog, printed on every run: the same lines for the same commit.
for rel, n, name in seen:
    print(f"  COMPAT({name})  {rel}:{n}")
print(f"compat comments: clean ({len(seen)} marker(s))")
