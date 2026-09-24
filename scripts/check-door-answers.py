#!/usr/bin/env python3
"""A door's answer is wrapped. Read the payload, not the envelope.

Every door the manager opens comes back through `_json_or_text`, which returns

    {"exit": <code>, "data": <what the command printed>}   # or "text" if it was not JSON

so a caller wanting a field of the command's own output has to unwrap it first.
On 23 Sep `_voice_for` did not, and read "cloud" straight off the envelope. The
answer was always None, None means "speak as the manager", and that is nobody's
error — so nothing logged, nothing failed, and every agent in the fleet spoke in
the manager's voice for an evening while the app was answering correctly in
220 ms.

That is the whole class: a wrong read on a wrapped answer is SILENT, because the
miss looks exactly like an absent value. It cannot announce itself at runtime,
so it gets caught here or by a person listening.

The rule: a `_json_or_text(...)` result may be used whole (returned, handed to a
result callback, logged), or unwrapped with `.get("data")`. Reading any other
key off it directly is the mistake.
"""
import pathlib
import re
import sys

ENVELOPE = {"data", "exit", "text"}
SERVER = pathlib.Path(__file__).resolve().parents[1] / "tb-voice" / "server"
CALL = re.compile(r"(?:(\w+)\s*=\s*)?_json_or_text\s*\(")
GET = re.compile(r'\.get\(\s*["\'](\w+)["\']')
# How far after the assignment to look for a read of it. Long enough for the
# handful of lines a door answer is normally picked apart in.
WINDOW = 6


def offences(path: pathlib.Path) -> list[str]:
    found = []
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        call = CALL.search(line)
        if not call:
            continue
        # Same line: `_json_or_text(...).get("cloud")` is wrong unless it is
        # the envelope's own key.
        tail = line[call.end():]
        for key in GET.findall(tail):
            if key not in ENVELOPE:
                found.append(f"{path.name}:{i + 1}: reads {key!r} off the envelope; "
                             f'unwrap with .get("data") first')
        name = call.group(1)
        if not name or ".get(" in tail:
            continue
        # Assigned whole: look for a read of that name shortly after.
        for j in range(i + 1, min(i + 1 + WINDOW, len(lines))):
            for key in re.findall(rf'\b{re.escape(name)}\.get\(\s*["\'](\w+)["\']', lines[j]):
                if key not in ENVELOPE:
                    found.append(f"{path.name}:{j + 1}: reads {key!r} off {name!r}, which is a "
                                 f'door envelope; unwrap with .get("data") first')
    return found


def main() -> int:
    if not SERVER.is_dir():
        return 0
    bad = [line for path in sorted(SERVER.glob("*.py")) for line in offences(path)]
    if bad:
        print("✗ a door's answer is being read off its envelope:", file=sys.stderr)
        for line in bad:
            print(f"    {line}", file=sys.stderr)
        print("  _json_or_text returns {\"exit\": ..., \"data\": ...}; the payload is under"
              " \"data\".", file=sys.stderr)
        return 1
    print("✓ every door answer is unwrapped before it is read")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
