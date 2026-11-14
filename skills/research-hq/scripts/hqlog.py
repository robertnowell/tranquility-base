#!/usr/bin/env python3
"""Read another agent's session log: the tail, an outline, a search, a range.

    hq-log tail    <session|path> [--tokens N]      the newest entries that fit N tokens
    hq-log outline <session|path>                   every message a person wrote, numbered
    hq-log search  <session|path> <regex> [-C N] [--max N] [-i]
    hq-log show    <session|path> <from>[-<to>] [--full]

Continue with pastes `tail` into the new agent's first message, so the new
agent begins with the recent conversation in its context. Everything older
stays in the log, and `search`, `outline` and `show` are how the new agent
reaches it. Ruled 14 Nov 2026: the handoff used to carry only a path and one
sentence asking the agent to read the end of the file.

One parser for both harnesses, and one numbering: an entry's number is its
position in the whole log, so a number printed by `search` is the number
`show` takes, and the numbers in a pasted tail stay valid afterwards.

Deterministic by construction: no model, no network, no clock. The same log
and the same arguments print the same bytes.
"""
import glob
import json
import os
import re
import sys

# A tool result longer than this is cut in the tail and in search context.
# `show --full` prints it whole. The cut says so and names the command.
CLIP = 4000
# Characters per token, for the budget only. Deliberately low: an estimate
# that is too generous overflows the destination's context window.
CHARS_PER_TOKEN = 3.5
DEFAULT_TOKENS = 100_000


# ---------------------------------------------------------------- locating

def locate(arg):
    """A path as given, else the log of that session id in either harness."""
    if os.path.isfile(arg):
        return arg
    home = os.path.expanduser("~")
    roots = [os.path.join(home, ".claude", "projects")]
    # Saved accounts keep their own config directory beside ~/.claude.
    roots += glob.glob(os.path.join(home, ".claude-*", "projects"))
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        roots.append(os.path.join(env, "projects"))
    for root in roots:
        hits = glob.glob(os.path.join(root, "*", arg + ".jsonl"))
        if hits:
            return hits[0]
    codex = os.environ.get("CODEX_HOME", os.path.join(home, ".codex"))
    hits = glob.glob(os.path.join(codex, "sessions", "**", "*" + arg + ".jsonl"),
                     recursive=True)
    if hits:
        return sorted(hits)[-1]
    return None


# ----------------------------------------------------------------- parsing

def _text(blocks):
    """The text of a content value that may be a string or a block list."""
    if isinstance(blocks, str):
        return blocks
    out = []
    for b in blocks or []:
        if isinstance(b, str):
            out.append(b)
        elif isinstance(b, dict):
            t = b.get("text")
            if isinstance(t, str):
                out.append(t)
            elif b.get("type") == "image":
                out.append("[image]")
    return "\n".join(x for x in out if x)


def _compact(value):
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def claude_entries(row):
    """Zero or more (role, text) for one Claude Code transcript record."""
    kind = row.get("type")
    if row.get("isSidechain"):
        return
    if kind == "system" and row.get("subtype") == "compact_boundary":
        yield ("note", "The harness compacted the conversation here. "
                       "Entries before this number were summarized for the agent.")
        return
    if kind not in ("user", "assistant"):
        return
    content = (row.get("message") or {}).get("content")
    if isinstance(content, str):
        if content.strip():
            yield ("user" if kind == "user" else "assistant", content)
        return
    for b in content or []:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text" and (b.get("text") or "").strip():
            yield ("user" if kind == "user" else "assistant", b["text"])
        elif t == "tool_use":
            yield ("tool-call", "%s %s" % (b.get("name", "?"), _compact(b.get("input"))))
        elif t == "tool_result":
            yield ("tool-result", _text(b.get("content")))
        elif t == "image":
            yield ("user", "[image]")
        # thinking blocks are the model's private reasoning, signed for one
        # model; they are not conversation and are left in the log.


def codex_entries(row):
    """Zero or more (role, text) for one Codex rollout record."""
    kind = row.get("type")
    p = row.get("payload") or {}
    if kind == "compacted":
        yield ("note", "The harness compacted the conversation here. "
                       "Entries before this number were summarized for the agent.")
        return
    if kind != "response_item":
        return
    t = p.get("type")
    if t == "message":
        role = p.get("role")
        text = _text(p.get("content"))
        if not text.strip() or role == "developer":
            return
        # Codex writes its own context as user messages. They are protocol.
        if role == "user" and text.lstrip().startswith(
                ("<environment_context>", "<user_instructions>", "<turn_aborted>")):
            return
        yield ("user" if role == "user" else "assistant", text)
    elif t in ("function_call", "custom_tool_call", "local_shell_call"):
        body = p.get("arguments") or p.get("input") or p.get("action") or ""
        yield ("tool-call", "%s %s" % (p.get("name", t), _compact(body)))
    elif t in ("function_call_output", "custom_tool_call_output"):
        out = p.get("output")
        yield ("tool-result", _text(out) if isinstance(out, list) else _compact(out))


def entries(path):
    """Every entry of the log, in file order: (number, stamp, role, text).

    Streams, because one rollout on the Mac this was written on is 642 MB.
    """
    n = 0
    parser = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            if parser is None:
                parser = codex_entries if "payload" in row else claude_entries
            stamp = row.get("timestamp") or ""
            for role, text in parser(row):
                n += 1
                yield (n, stamp if isinstance(stamp, str) else "", role, text)


# --------------------------------------------------------------- rendering

def clip(text, number, full=False):
    if full or len(text) <= CLIP:
        return text
    return (text[:CLIP] + "\n[... %d more characters. hq-log show <log> %d --full prints all of it.]"
            % (len(text) - CLIP, number))


def render(entry, full=False):
    number, stamp, role, text = entry
    head = "[%d] %s" % (number, role)
    if stamp:
        head += " " + stamp[:19].replace("T", " ")
    if role in ("tool-result", "tool-call"):
        text = clip(text, number, full)
    return head + "\n" + text.rstrip() + "\n"


# ---------------------------------------------------------------- commands

def cmd_tail(path, tokens):
    """The newest entries whose rendering fits the budget, oldest first.

    Cut at an entry boundary, never inside one. One entry larger than the
    whole budget is clipped to it, so the tail is never empty.
    """
    budget = int(tokens * CHARS_PER_TOKEN)
    kept, used, total = [], 0, 0
    # A deque over the stream would hold the whole log; keep only what could
    # still fit, by dropping from the front as the back grows.
    for e in entries(path):
        total = e[0]
        r = render(e)
        kept.append((e[0], r))
        used += len(r) + 1
        while used > budget and len(kept) > 1:
            used -= len(kept[0][1]) + 1
            kept.pop(0)
    if not kept:
        print("(the log holds no conversation yet)")
        return 0
    if used > budget:
        kept[0] = (kept[0][0], kept[0][1][:budget] + "\n[... cut to fit.]\n")
    first = kept[0][0]
    if first > 1:
        print("[entries 1 to %d are not shown here. They are in the log: "
              "hq-log outline, hq-log search and hq-log show reach them.]\n" % (first - 1))
    print("\n".join(r for _, r in kept), end="")
    print("\n[end of log: entry %d of %d]" % (kept[-1][0], total))
    return 0


def cmd_outline(path):
    any_ = False
    for number, stamp, role, text in entries(path):
        if role not in ("user", "note"):
            continue
        any_ = True
        first = " ".join(text.split())[:160]
        print("[%d] %s %s  %s" % (number, role, stamp[:16].replace("T", " "), first))
    if not any_:
        print("(no message from a person in this log)")
    return 0


def cmd_search(path, pattern, context, limit, ignore_case):
    try:
        rx = re.compile(pattern, re.IGNORECASE if ignore_case else 0)
    except re.error as err:
        print("not a regular expression: %s" % err, file=sys.stderr)
        return 2
    hits = 0
    more = 0
    for number, stamp, role, text in entries(path):
        found = [m for m in rx.finditer(text)]
        if not found:
            continue
        if hits >= limit:
            more += 1
            continue
        hits += 1
        print("[%d] %s %s" % (number, role, stamp[:19].replace("T", " ")))
        lines = text.split("\n")
        shown = set()
        for i, line in enumerate(lines):
            if rx.search(line):
                for j in range(max(0, i - context), min(len(lines), i + context + 1)):
                    shown.add(j)
        last = -2
        printed = 0
        for j in sorted(shown):
            if printed >= 40:
                print("    [... more matching lines in this entry. hq-log show <log> %d]" % number)
                break
            if j != last + 1 and last >= 0:
                print("    --")
            line = lines[j]
            if len(line) > 400:
                m = rx.search(line)
                at = m.start() if m else 0
                a = max(0, at - 160)
                line = ("..." if a else "") + line[a:a + 400] + "..."
            print("    " + line)
            last = j
            printed += 1
        print()
    if hits == 0:
        print("no entry matches %r" % pattern)
        return 1
    if more:
        print("[%d more matching entries not shown. Raise --max or narrow the pattern.]" % more)
    return 0


def cmd_show(path, span, full):
    m = re.fullmatch(r"(\d+)(?:-(\d+))?", span)
    if not m:
        print("give one entry number, or a range such as 120-140", file=sys.stderr)
        return 2
    lo = int(m.group(1))
    hi = int(m.group(2) or lo)
    any_ = False
    for e in entries(path):
        if e[0] > hi:
            break
        if e[0] >= lo:
            any_ = True
            print(render(e, full=full))
    if not any_:
        print("no entry %s in this log" % span)
        return 1
    return 0


def main(argv):
    if len(argv) < 2 or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2
    command, target, rest = argv[0], argv[1], argv[2:]
    path = locate(target)
    if not path:
        print("no session log found for %s" % target, file=sys.stderr)
        return 2

    def option(name, default, cast=int):
        if name in rest:
            i = rest.index(name)
            value = cast(rest[i + 1])
            del rest[i:i + 2]
            return value
        return default

    try:
        if command == "tail":
            return cmd_tail(path, option("--tokens", DEFAULT_TOKENS))
        if command == "outline":
            return cmd_outline(path)
        if command == "search":
            context = option("-C", 1)
            limit = option("--max", 20)
            ignore = "-i" in rest
            rest[:] = [r for r in rest if r != "-i"]
            if not rest:
                print("usage: hq-log search <session|path> <regex>", file=sys.stderr)
                return 2
            return cmd_search(path, rest[0], context, limit, ignore)
        if command == "show":
            full = "--full" in rest
            rest[:] = [r for r in rest if r != "--full"]
            if not rest:
                print("usage: hq-log show <session|path> <from>[-<to>]", file=sys.stderr)
                return 2
            return cmd_show(path, rest[0], full)
    except (IndexError, ValueError):
        print("an option is missing its number", file=sys.stderr)
        return 2
    except BrokenPipeError:
        return 0
    print("unknown command %s. Commands: tail, outline, search, show." % command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
