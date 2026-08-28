#!/usr/bin/env python3
"""No em dashes in copy a human reads in the product.

Asked for directly, 27 Aug, on a card that said "Couldn't move that session
under tmux — it is still running in its own terminal." The em dash is not a
house mark and it reads as machine-written; a sentence that needs one is a
sentence that wanted a full stop.

    "why is there an em dash in our product copy"

This exists because the rule kept coming back: the repo carries a
`copy/no-em-dashes-and-a-tooltip` branch in its history, which means it was
fixed once by hand and returned. A rule nothing checks is a preference, and
preferences lose to whoever types next.

SCOPE is deliberately the panel, not the repo. `Sources/TranquilityApp` plus
the waiting-panel text is where copy a user reads actually lives. Elsewhere an
em dash is usually correct and this must not cry wolf there: the model prompts
in `Summarizer`, the generated HTML in `HomeBase`, the title separators, the
sanitizer's own dash regex, and `tbase`'s terminal output are all read by
someone other than the person holding the panel.

Exempt, for the same reasons `check-key-names.sh` exempts them: comments (they
are for us), diagnostics (`Permissions.log`, `trace`, `lat`, `log`), and an
explicit `house-copy:exempt` marker, so a deliberate exception is a decision
somebody made rather than a hole in the pattern.
"""
import pathlib, re, sys

DASHES = {"—": "em dash", "–": "en dash"}
ROOT = pathlib.Path(__file__).resolve().parent.parent
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')
# `because:` labels a cause for the log and the drills, never for a card.
DIAGNOSTIC = re.compile(r'(Permissions\.log\(|\btrace\?\(|\blog\(|\blat\(|\bprint\(|\bbecause:)')

TARGETS = sorted(ROOT.glob("Sources/TranquilityApp/**/*.swift")) + [
    ROOT / "Sources/TranquilityCore/WaitingAt.swift",
]

# A Swift message is usually built across several lines with `+ "..."`, and the
# thing that says whether it is a diagnostic is the FIRST line. Judging each
# line alone was the guard's own first bug: it read every continuation of a
# `Permissions.log` call as unattributed copy and reported nineteen violations,
# seventeen of which were log lines. So statements are reassembled before they
# are judged.
def statements(lines):
    i = 0
    while i < len(lines):
        start, block = i, [lines[i]]
        i += 1
        # `+ "..."` concatenations and a ternary's `? "..."` / `: "..."`
        # branches are all continuations of the statement above them.
        while i < len(lines) and re.match(r'\s*([+?:]\s*)?"', lines[i]):
            block.append(lines[i])
            i += 1
        yield start + 1, "\n".join(block)

bad = []
for path in TARGETS:
    if not path.exists():
        continue
    for n, stmt in statements(path.read_text().splitlines()):
        head = stmt.lstrip()
        if (head.startswith("//") or DIAGNOSTIC.search(stmt)
                or "house-copy:exempt" in stmt):
            continue
        for lit in LITERAL.findall(stmt):
            for ch, name in DASHES.items():
                if ch in lit:
                    bad.append((path.relative_to(ROOT), n, name,
                                " ".join(stmt.split())))

for rel, n, name, text in bad:
    print(f"{rel}:{n}: {name} in product copy -> {text[:88]}")
print(f"\n{len(bad)} dash(es) in product copy" if bad else "house copy: clean")
sys.exit(1 if bad else 0)
