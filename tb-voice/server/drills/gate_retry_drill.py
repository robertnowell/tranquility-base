"""A dead socket costs one retry, not a turn.

Measured inside the bot on 28 Sep: 70 successful gate calls at p50 102ms,
p99 153ms, max 153ms -- and 4 that never answered, at the 8s ceiling. Nothing
in between. A distribution with a hole that size is not a slow server; it is a
request written to a connection the server had already closed, which HTTP/1.1
cannot detect before writing. The traceback agreed: `AsyncHTTP11Connection
[... CLOSED, Request Count: 1]`.

So the first attempt IS the detection, and the only cure is to write again on a
connection that cannot be the same one. This drills that, and drills the limits
on it: only for a timeout, only once, and never for an answer the gate actually
gave.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import httpx

import manager as M


class Recorder:
    """Stands in for httpx.AsyncClient. Records every post and every close, so
    the drill can tell a retry on a fresh connection from a retry on the same
    one -- which would be no cure at all."""

    made = 0

    def __init__(self, outcomes, log):
        Recorder.made += 1
        self.n = Recorder.made
        self._outcomes = outcomes
        self._log = log
        self.closed = False

    async def post(self, url, json=None):
        self._log.append(("post", self.n))
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    async def aclose(self):
        self.closed = True
        self._log.append(("close", self.n))


class Answer:
    status_code = 200
    def raise_for_status(self): pass
    def json(self): return {"answers": {"addressed": {"noul": 0.9}}}


def client_with(outcomes, log):
    c = M.JevClient.__new__(M.JevClient)
    c._headers = {"Authorization": "Bearer x"}
    c._client = Recorder(outcomes, log)
    M.httpx = httpx
    return c


async def main() -> int:
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    # The happy path is untouched: one write, no close, no second connection.
    log = []
    c = client_with([Answer()], log)
    r = await M.JevClient._post(c, {"body": 1})
    check("an answer is returned on the first write", r.status_code == 200)
    check("and nothing is retried or closed", log == [("post", c._client.n)])

    # A timeout: close the pool, build a NEW client, write once more.
    log = []
    made_before = Recorder.made
    c = client_with([httpx.ReadTimeout(""), None], log)
    first = c._client
    # The retry builds a real httpx client, so hand it a Recorder instead.
    original = httpx.AsyncClient
    second_outcomes = [Answer()]
    httpx.AsyncClient = lambda **kw: Recorder(second_outcomes, log)
    try:
        r = await M.JevClient._post(c, {"body": 1})
    finally:
        httpx.AsyncClient = original
    check("the timeout is retried and answered", getattr(r, "status_code", None) == 200)
    check("the dead pool is closed first", first.closed)
    check("and the retry is on a DIFFERENT connection, which is the whole point",
          [n for kind, n in log if kind == "post"] == [first.n, first.n + 1])

    # Twice is not a strategy: a second timeout is the gate's answer.
    log = []
    c = client_with([httpx.ReadTimeout(""), None], log)
    httpx.AsyncClient = lambda **kw: Recorder([httpx.ReadTimeout("")], log)
    try:
        raised = None
        try:
            await M.JevClient._post(c, {"body": 1})
        except httpx.TimeoutException as e:
            raised = e
    finally:
        httpx.AsyncClient = original
    check("a second timeout is raised, not retried again", raised is not None)
    check("exactly two writes, never three", len([1 for k, _ in log if k == "post"]) == 2)

    # Anything that is not a timeout is the gate talking. Retrying it would
    # ask the same question twice and get the same answer twice.
    log = []
    boom = httpx.ConnectError("refused")
    c = client_with([boom], log)
    raised = None
    try:
        await M.JevClient._post(c, {"body": 1})
    except httpx.ConnectError as e:
        raised = e
    check("a non-timeout failure is not retried", raised is boom)
    check("and the pool it came from is left alone", len(log) == 1)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
