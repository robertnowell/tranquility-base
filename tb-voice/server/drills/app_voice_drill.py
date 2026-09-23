"""The app's own sentence must not become a command — without closing the mic.

23 Sep, 20:03 to 20:04: the app read three session announcements aloud in their
own voices and the manager transcribed all three back, verbatim, as things the
developer had said. The client's canceller never had them: they go out through
the app's synthesizer, not the connection, so they are not in its reference.

The fix must not be deafness. On a cancelling client the microphone stays open
the whole time — that is what the canceller is for — and the app's line is
dropped afterwards by comparing what was heard against what the app was asked
to say. Real speech over the top survives, which is the case that matters.
"""
import sys, time

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import app_echo
import session
from echo import EchoGate

# Verbatim from app.log, 23 Sep.
SAID = [
    ("The cutover is complete; we're now researching AGI House SF Voice AI "
     "Hackathon sponsors and judges for Tranquility Base.",
     "The cutover is complete. We're now researching AGI. House SF"),
    ("The cutover is done and we're now on the stated goal, so yes, we're making progress.",
     "The cutover is done and we're now in the stated goal, so yes"),
    ("The facts don't say anything about rollback plans or failure procedures "
     "for the echo gate cutover.",
     "The facts don't say anything about rollback plans or failure"),
]
# Things a person says. None may ever be taken for the line being read.
PEOPLE = ["Can you invite the next agent to speak?", "Stop.", "No, wait.",
          "Tell it to use the staging database instead.",
          "What's the goal on that one?", "Say what's next."]


def main() -> int:
    s = session.bind()
    fails = []

    def check(what, got, want):
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}")
        if got != want:
            fails.append(what)

    print("the microphone stays open on a cancelling client, even while the app reads")
    rtc, ws = EchoGate(cancels_own_voice=True), EchoGate(cancels_own_voice=False)
    s.external_until.update({"t": time.monotonic() + 9, "text": SAID[0][0]})
    check("cancelling client still hears the room", rtc.gated(), False)
    check("plain client, with no canceller at all, is fed silence", ws.gated(), True)

    print("the app's line, back off the microphone")
    for spoken, heard in SAID:
        s.external_until.update({"t": time.monotonic() + 9, "text": spoken})
        check(f"dropped: {heard[:52]!r}", app_echo.is_app_echo(heard), True)

    print("a person, while the app is reading")
    s.external_until.update({"t": time.monotonic() + 9, "text": SAID[0][0]})
    for said in PEOPLE:
        check(f"kept: {said!r}", app_echo.is_app_echo(said), False)

    print("and once the app has long finished, its own line is a command again")
    s.external_until.update({"t": time.monotonic() - 60, "text": SAID[0][0]})
    check("past the window, nothing is dropped", app_echo.is_app_echo(SAID[0][1]), False)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
