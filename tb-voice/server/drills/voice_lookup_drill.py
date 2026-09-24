"""The voice comes back under "data", like every other door's answer.

23 Sep: the app answered `tbase voice` correctly and in 220 ms —

    manager: 98bcd108 speaks as EGxJIQ5TF187oclOp8aT
    manager wire: answered tbase voice -> 0 in 220 ms

— and every agent still spoke in the manager's voice, because the bot read
"cloud" off the wrapper rather than off the payload. `_json_or_text` returns
{"exit": code, "data": ...}, so the read returned None, and None means "use the
manager's voice". Nothing failed, nothing logged, and the only symptom was the
wrong voice.

This drives the parse against the exact bytes the app sent that night.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tools import _json_or_text

# Verbatim from app.log, 01:50:14.
ANSWERED = '{"cloud":"EGxJIQ5TF187oclOp8aT","system":"com.apple.voice.premium.en-US.Ava"}'


def cloud_voice(code: int, out: str) -> str | None:
    """The same read manager._voice_for makes."""
    data = _json_or_text(code, out).get("data") or {}
    return (data.get("cloud") if isinstance(data, dict) else None) or None


def main() -> int:
    fails = []

    def check(what, got, want):
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}: {got!r}"
              + ("" if got == want else f", wanted {want!r}"))
        if got != want:
            fails.append(what)

    check("the session's own voice, from the answer the app really sent",
          cloud_voice(0, ANSWERED), "EGxJIQ5TF187oclOp8aT")
    check("a session with no cloud voice falls back, rather than raising",
          cloud_voice(0, '{"cloud":null,"system":"com.apple.voice.premium.en-AU.Karen"}'), None)
    check("an empty string is not a voice", cloud_voice(0, '{"cloud":""}'), None)
    check("a door that failed is not a voice", cloud_voice(1, "usage: tbase ..."), None)
    check("and neither is nothing at all", cloud_voice(0, ""), None)

    # The shape that caused it: reading the wrapper instead of the payload.
    wrapper = _json_or_text(0, ANSWERED)
    check("the wrapper itself has no 'cloud' — this is the bug, pinned",
          wrapper.get("cloud"), None)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
