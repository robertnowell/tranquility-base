"""The loop's mechanics, with the model scripted (hf-6).

loop_eval.py asks the real model real questions; this checks what the loop
itself promises, whatever the model does:

  answers:   tool calls, then a plain answer, is the answer; the tools ran
             (several at once when asked for together).
  failure:   a tool that raises or times out is reported to the model as an
             error, and the loop goes on.
  steps:     at the step cap the model is offered no tools; if it still
             writes a call as text, nothing is said.
  time:      a model slower than the budget ends the loop without an answer.
  holding:   past HOLD_AFTER_S, the first tool call starts the holding line,
             once.
  length:    an answer over max_words is asked for once more, shorter.
  markup:    thinking and call markup never reach the answer.

    uv run python drills/loop_drill.py
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx  # noqa: E402

import loop as loopmod  # noqa: E402
from loop import Loop, Tool  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def call(name, args=None, cid=None):
    return {"id": cid or f"c-{name}", "type": "function", "function": {"name": name, "arguments": json.dumps(args or {})}}


def scripted(replies, delay=0.0, seen=None):
    """A model that answers each request with the next scripted message."""
    replies = list(replies)

    async def handler(request: httpx.Request):
        body = json.loads(request.content)
        if seen is not None:
            seen.append(body)
        if delay:
            await asyncio.sleep(delay)
        msg = replies.pop(0) if replies else {"content": "out of script"}
        return httpx.Response(200, json={"choices": [{"message": {"role": "assistant", **msg}}]})

    return Loop(httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://model"), "scripted")


async def main():
    ran = []

    async def slow_read(a):
        ran.append(("start", a.get("agent"), time.monotonic()))
        await asyncio.sleep(0.3)
        ran.append(("end", a.get("agent"), time.monotonic()))
        return {"text": f"record of {a.get('agent')}"}

    async def broken(a):
        raise RuntimeError("the Mac said no")

    async def hangs(a):
        await asyncio.sleep(30)

    tools = [Tool("read", "read", slow_read, {"agent": {"type": "string"}}), Tool("broken", "broken", broken),
             Tool("hangs", "hangs", hangs)]

    # answers, several at once
    seen = []
    lp = scripted([{"content": "", "tool_calls": [call("read", {"agent": "a"}, "1"), call("read", {"agent": "b"}, "2")]},
                   {"content": "We found it in the record."}], seen=seen)
    o = await lp.run("sys", "q", tools)
    check(o.answer == "We found it in the record." and o.steps == 2, "answers: the plain reply after the tools is the answer")
    starts = [t for k, _, t in ran if k == "start"]
    ends = [t for k, _, t in ran if k == "end"]
    check(len(starts) == 2 and max(starts) < min(ends), "answers: two calls asked for together run at once")
    tool_msgs = [m for m in seen[-1]["messages"] if m["role"] == "tool"]
    check([m["tool_call_id"] for m in tool_msgs] == ["1", "2"] and "record of a" in tool_msgs[0]["content"],
          "answers: each result goes back under its own call id")

    # failure
    seen = []
    lp = scripted([{"content": "", "tool_calls": [call("broken"), call("nosuch")]}, {"content": "Could not read it."}], seen=seen)
    o = await lp.run("sys", "q", tools)
    errs = [json.loads(m["content"]) for m in seen[-1]["messages"] if m["role"] == "tool"]
    check(o.answer == "Could not read it." and all("error" in e for e in errs) and len(errs) == 2,
          "failure: a raising tool and an unknown one come back as errors, and it goes on")

    # steps
    seen = []
    lp = scripted([{"content": "", "tool_calls": [call("read", {"agent": "a"})]}] * 2
                  + [{"content": '<minimax:tool_call><invoke name="read"></invoke></minimax:tool_call>'}], seen=seen)
    o = await lp.run("sys", "q", tools, max_steps=3)
    check("tools" not in seen[-1] and "tools" in seen[0], "steps: the last step is offered no tools")
    check(o.answer is None and o.stopped == "steps", "steps: a call written as text at the cap says nothing")

    # time
    lp = scripted([{"content": "", "tool_calls": [call("hangs")]}, {"content": "late"}])
    t0 = time.monotonic()
    o = await lp.run("sys", "q", tools, budget_s=0.6)
    check(o.answer is None and o.stopped == "time" and time.monotonic() - t0 < 1.5,
          "time: a tool past the budget ends the loop, without an answer, on time")

    # holding
    held = []

    async def on_hold(line):
        held.append(line)

    loopmod.HOLD_AFTER_S = 0.1
    lp = scripted([{"content": "", "tool_calls": [call("read", {"agent": "a"})]},
                   {"content": "", "tool_calls": [call("read", {"agent": "b"})]}, {"content": "Done."}], delay=0.15)
    o = await lp.run("sys", "q", [Tool("read", "read", slow_read, {"agent": {"type": "string"}}, holding="Reading.")],
                     on_hold=on_hold)
    check(held == ["Reading."], "holding: said once, in the first late tool's words")

    # length
    long = " ".join(["word"] * 50)
    seen = []
    lp = scripted([{"content": long}, {"content": "Short and true."}], seen=seen)
    o = await lp.run("sys", "q", tools, max_words=30)
    check(o.answer == "Short and true." and len(seen) == 2 and "at most 30 words" in seen[-1]["messages"][-1]["content"],
          "length: over the limit, asked once more for a shorter one")

    # markup
    lp = scripted([{"content": "<think>let me see</think>We found the bug."}])
    o = await lp.run("sys", "q", tools)
    check(o.answer == "We found the bug.", "markup: thinking never reaches the answer")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
