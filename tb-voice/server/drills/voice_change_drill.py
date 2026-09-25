"""A change of speaker is ONE reconnect, and the framework does it.

23 Sep: the first live session on per-session voices played every line high and
fast — the manager's own voice too, for the rest of the session. `use_voice`
called `_update_settings` and then disconnected and reconnected the socket
itself, not knowing that `voice` is in `ElevenLabsTTSSettings.URL_FIELDS` and
that the base class already reconnects for those. Two handshakes raced, and
what came back was a socket the service had not agreed an output format with,
so 24 kHz frames carried audio that was not 24 kHz.

This asserts the contract that made that a bug — `voice` is a URL field, so
the base reconnects — rather than the symptom, which needs a speaker.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import inspect

from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
from pipecat.services.elevenlabs.tts_base import ElevenLabsTTSBase

from tts import SpokenTTSService


def main() -> int:
    fails = []

    def check(what, got, want=True):
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}")
        if got != want:
            fails.append(what)

    check("changing the voice is a URL-level change",
          "voice" in ElevenLabsTTSService.Settings.URL_FIELDS)
    check("so the base class owns the reconnect for it",
          "_disconnect" in inspect.getsource(ElevenLabsTTSBase._update_settings)
          and "_connect" in inspect.getsource(ElevenLabsTTSBase._update_settings))

    source = inspect.getsource(SpokenTTSService.use_voice)
    check("and use_voice does NOT reconnect a second time",
          "_disconnect()" not in source and "_connect()" not in source)
    check("it changes the voice through the settings, which is the supported path",
          "_update_settings" in source)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
