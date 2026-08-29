#!/usr/bin/env python3
"""An AEDesc borrowed from NSAppleEventDescriptor is never copied and never disposed.

Ruled 29 Aug 2026, after this exact mistake cost three days of crash hunting.

`NSAppleEventDescriptor.aeDesc` hands back a pointer to storage the wrapper
still owns and still disposes in its own dealloc. Copying that struct out with
`.pointee` and then calling `AEDisposeDesc` on the copy frees the same storage
twice. The heap is corrupted from that moment, but the process does not die
there: it dies later, in whatever code touches the poisoned memory next. The
retained crash corpus blamed GRDB row teardown, SQLite statement machinery,
Swift witness tables and SwiftUI's AttributeGraph in turn. All of them were
victims.

    "the stack names the victim, the deployment boundary names the suspect"

So: borrow the pointer, keep the wrapper alive with `withExtendedLifetime`,
and let the wrapper do the disposing it was always going to do anyway.
Comments are exempt; they are how the next person learns why.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Sources"
BAD = [
    (re.compile(r"\.aeDesc\s*\??\s*\.\s*pointee"),
     "copies the AEDesc out of a wrapper that still owns it; borrow `.aeDesc` instead"),
    (re.compile(r"\bAEDisposeDesc\s*\("),
     "disposes storage NSAppleEventDescriptor disposes itself; delete the call"),
]

failures = []
for path in sorted(ROOT.rglob("*.swift")):
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip().startswith("//"):
            continue
        for pattern, why in BAD:
            if pattern.search(line):
                rel = path.relative_to(ROOT.parent)
                failures.append(f"{rel}:{n}: {why}\n    {line.strip()}")

if failures:
    print("borrowed-descriptor check FAILED:\n", file=sys.stderr)
    for f in failures:
        print(f"  {f}\n", file=sys.stderr)
    sys.exit(1)
print("✓ borrowed-descriptor check: no AEDesc copies or manual disposals")
