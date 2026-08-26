#!/usr/bin/env python3
"""Every modifier glyph in human-visible text carries its key's NAME.

Ruled 26 Aug 2026, generalising a rule the panel already held in one place:
`StateLegend.gettingStartedMessage` spells out "Control + Option" and a drill
asserts it contains no bare marks. The rest of the app did not follow -- the
menu hint, the status-item tooltip, two mic status lines and a spoken prompt
all shipped bare glyphs.

    "a bare glyph is a shape most people cannot say out loud, and a key you
     cannot name is a key you cannot press"

So: inside a Swift string literal, every one of these marks must be followed
by its name. Comments are exempt (they are for us) and so is `Permissions.log`
(a diagnostic, read by whoever is grepping it, never by a user).
"""
import pathlib, re, sys

NAMES = {"⌃": ("Ctrl", "Control"), "⌥": ("Option", "Opt"),
         "⇧": ("Shift",), "⌘": ("Cmd", "Command")}
ROOT = pathlib.Path(__file__).resolve().parent.parent
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')

bad = []
for path in sorted(ROOT.glob("Sources/**/*.swift")):
    for n, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.lstrip()
        # Comments are for us; `Permissions.log` is a diagnostic read by
        # whoever is grepping it. Anything else that genuinely needs a bare
        # mark -- a drill asserting one is ABSENT, a log label passed as an
        # argument -- says so out loud with the marker, so an exemption is a
        # decision somebody made rather than a hole in the pattern.
        if (stripped.startswith("//") or "Permissions.log(" in line
                or "key-names:exempt" in line):
            continue
        for lit in LITERAL.findall(line):
            for i, ch in enumerate(lit):
                if ch not in NAMES:
                    continue
                rest = lit[i + 1:].lstrip()
                if not rest.startswith(NAMES[ch]):
                    bad.append((path.relative_to(ROOT), n, ch, line.strip()))

for rel, n, ch, text in bad:
    print(f"{rel}:{n}: bare {ch} in human-visible text -> {text[:88]}")
print(f"\n{len(bad)} bare modifier glyph(s)" if bad else "key names: clean")
sys.exit(1 if bad else 0)
