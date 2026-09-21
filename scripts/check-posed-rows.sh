#!/usr/bin/env python3
"""A posed row with a turn says the turn exists.

Ruled 21 Sep 2026. #552 made `SessionRow.hasRecordedTurn` the one fact a
lit row's tap consults to choose the card or the door; the read state had
been standing in for it and lied for every answered row. The unit fixtures
were updated. The panel drills were not, and `closedRows` and
`crobotFinish` went red on the deploy for posing "a row with a turn" as
`read: .unread` or `.opened` with nothing said about the turn itself. The
same drill's own comment records the identical miss on 15 Sep (#458 changed
the rule, "updated the unit fixtures but not this drill"). Rule 7: `swift
test` cannot see a drill's fixture, so the fixture is checked here.

So: in Sources/TranquilityApp, any `SessionRow(` literal whose `read:` is
`.unread` or `.opened` also passes `hasRecordedTurn:`. A waiting or heard
turn IS a recorded turn; a fixture that says the one and not the other is
the proxy this rule retired. The assembler in TranquilityCore is out of
scope: it states the fact from the store on every band.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
bad = []
for path in sorted(ROOT.glob("Sources/TranquilityApp/**/*.swift")):
    text = path.read_text()
    for m in re.finditer(r"\bSessionRow\(", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            c = text[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            i += 1
        literal = text[m.end():i - 1]
        if re.search(r"\bread:\s*\.(unread|opened)\b", literal) \
                and not re.search(r"\bhasRecordedTurn:", literal):
            line = text.count("\n", 0, m.start()) + 1
            bad.append(f"{path.relative_to(ROOT)}:{line}: a posed row with a "
                       f"waiting or heard turn does not say the turn exists")

if bad:
    print("✗ a posed row with a turn says the turn exists "
          "(scripts/check-posed-rows.sh):", file=sys.stderr)
    for b in bad:
        print("    " + b, file=sys.stderr)
    sys.exit(1)
print("✓ posed rows: every waiting or heard fixture states its recorded turn")
