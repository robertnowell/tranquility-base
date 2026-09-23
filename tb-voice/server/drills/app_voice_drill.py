"""The canceller in the client removes our voice. It cannot remove the app's.

23 Sep, 20:03 to 20:04: the app read three session announcements aloud in their
own voices, and the manager transcribed all three back, verbatim, as things the
developer had said —

    20:03:40.556  app   "The cutover is complete; we're now researching AGI House SF…"
    20:03:50.016  heard "The cutover is complete. We're now researching AGI. House SF"

— because the WebRTC cutover turned the echo gate off wholesale on the grounds
that the client cancels echo. It cancels the audio it plays itself; the app's
synthesizer is a different output path and is not in its reference signal. The
app-speech window went off with the rest of the gate.

So: on a cancelling client the gate stays open while the MANAGER speaks (that is
what makes interruption possible) and closes while the APP speaks.
"""
import sys, time

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import session
from echo import EchoGate


def main() -> int:
    s = session.bind()
    rtc, ws = EchoGate(cancels_own_voice=True), EchoGate(cancels_own_voice=False)
    fails = []

    def check(what, gate, want):
        got = gate.gated()
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}: gated={got}, wanted {want}")
        if got != want:
            fails.append(what)

    print("quiet")
    check("cancelling client, nobody speaking", rtc, False)
    check("plain client, nobody speaking", ws, False)

    print("the manager's own voice, which the client subtracts")
    s.bot_voice["speaking"] = True
    check("cancelling client hears the room", rtc, False)
    check("plain client is fed silence", ws, True)
    s.bot_voice["speaking"] = False
    s.bot_voice["stopped_at"] = time.monotonic()

    print("the app's voice, which nothing subtracts")
    s.external_until["t"] = time.monotonic() + 5
    check("cancelling client is fed silence", rtc, True)
    check("plain client is fed silence", ws, True)

    print("after the app's line, past the tail")
    s.external_until["t"] = time.monotonic() - 5
    s.bot_voice["stopped_at"] = time.monotonic() - 5
    check("cancelling client hears the room again", rtc, False)
    check("plain client hears the room again", ws, False)

    print("PASS" if not fails else f"FAIL: {', '.join(fails)}")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
