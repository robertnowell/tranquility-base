#!/usr/bin/env python3
"""A grid row is dated by what its conversation last said, never by its file.

Ruled 15 Sep 2026. #458 gave `SessionRow.lastActivity` the transcript's
mtime, and the next afternoon a green row whose last turn was 22:01 the
night before sat second on the panel: Claude Code's Remote Control bridge
appends a `bridge-session` line to every idle transcript when it
reconnects, and each one moves the file without the conversation saying a
word. `SessionActivity.Evidence` already keeps the two clocks apart and its
own comment calls dating a verdict by the file "the failure that shipped
on 18 Aug"; the sort key simply picked the wrong one.

    "a lamp lit by a file" is one failure; a row dated by a file is the
    same failure wearing a different field.

So: in Sources/, no `lastActivity:` argument may be fed from `modifiedAt`,
`modificationDate` or `contentModificationDate`. The argument and its value
can span lines (they do, in GridRows), so the check reads the statement,
not the line. `SessionDiscovery`'s dead-band `lastActivityAt` is out of
scope: the dead band is never ordered by it.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILE_CLOCKS = re.compile(r"modifiedAt|modificationDate|contentModificationDate")
bad = []
for path in sorted(ROOT.glob("Sources/**/*.swift")):
    text = path.read_text()
    for m in re.finditer(r"\blastActivity:", text):
        # The argument's value runs to the next top-level `,` or `)`.
        depth, i = 0, m.end()
        while i < len(text):
            c = text[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                break
            i += 1
        value = text[m.end():i]
        if FILE_CLOCKS.search(value):
            line = text.count("\n", 0, m.start()) + 1
            bad.append(f"{path.relative_to(ROOT)}:{line}: lastActivity read from a file clock: "
                       f"{' '.join(value.split())}")

if bad:
    print("✗ a row is dated by its conversation, never by its file "
          "(scripts/check-row-dates.sh):", file=sys.stderr)
    for b in bad:
        print("    " + b, file=sys.stderr)
    sys.exit(1)
print("✓ row dates: no lastActivity reads a file clock")
