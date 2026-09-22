"""The open message: dictation with a destination.

Ruled 21 Sep after the 12:58 brief was judged as fourteen commands and the
start it asked for was cancelled by the next breath. The research (long
dictation in always-listening voice agents, 21 Sep) found nobody in the field
detects the end of a dictated brief from silence: every system that gathers
long input ends it on an explicit signal and reads a message back before
sending. So the manager carries one piece of state, an open message, and:

  - the destination is settled at the door, before a word is spent;
  - while it is open every word is the message, no intent is judged, no
    action is taken, nothing is said;
  - it closes on a phrase ("send it", "message complete"), or on your yes
    after one read-back that follows 30 s of silence; no pause ever sends;
  - "never mind" drops it; "send this to X instead" re-picks the destination.

The phrases below are the certain path: a short turn that is one of them
sends without waiting for a model. Jev backs them up for the rest.
"""

import os
import re
import time

READBACK_SECS = float(os.getenv("TB_READBACK_SECS", "30"))
SHORT_TURN_WORDS = 10

SEND = ("send it", "send that", "send this", "send the message", "send message", "send now",
        "message complete", "that's it", "that's the message", "that is the message",
        "that's all", "go ahead and send", "yes send", "yes, send", "okay send", "ok send",
        "over and out", "end of message")
HOLD = ("not yet", "wait", "hold on", "hold off", "don't send", "do not send", "one sec",
        "one second", "give me a minute", "not done", "no")
CANCEL = ("never mind", "nevermind", "scrap that", "scrap it", "forget it", "cancel that",
          "cancel the message", "drop it", "discard")


_TRAILING = re.compile(
    r"(?:(?:[,.;:!?]\s*(?:(?:and|so|okay|ok|then|yeah)[, ]+)*|\s+(?:and|so|then)\s+)(?:"
    + "|".join(re.escape(p) for p in sorted(SEND, key=len, reverse=True))
    + r")[.!]*\s*)+$",
    re.IGNORECASE)


def _norm(text: str) -> str:
    return re.sub(r"[^a-z' ]+", " ", text.lower()).strip()


def _short(text: str) -> bool:
    return len(text.split()) <= SHORT_TURN_WORDS


FILLERS = {"um", "uh", "mm", "hmm", "mm-hmm", "mhm", "yeah", "yep", "okay", "ok", "so", "like", "right", "well", "er", "ah"}


def filler_only(text: str) -> bool:
    """A fragment the segmenter cut out of a breath: "Um," "Yeah." "Mm-hmm."
    Nothing a message wants; an answer to the read-back is judged before this."""
    words = _norm(text).replace("-", " ").split()
    return bool(words) and all(w in FILLERS for w in words)


def continues(previous: str) -> bool:
    """The previous fragment was cut mid-sentence: whatever comes next is its
    continuation and can never be a verdict on its own. 16:15:53: "I'm not sure
    where" / "ready to send." / "Quite yet." sent the message."""
    return bool(previous) and not previous.rstrip().endswith((".", "?", "!"))


def classify(text: str, previous: str = "") -> tuple[str, str]:
    """The certain path. Returns (verdict, remainder): verdict is one of
    send / hold / cancel / retarget / content; remainder is the content part of
    a turn that ends in a send phrase ("...and that's it, send it")."""
    if continues(previous):
        return "content", text
    n = _norm(text)
    if _short(n):
        cue = any(p in n for p in ("instead", "not that one", "the other one", "wrong agent", "wrong one"))
        if cue or (n.startswith("send") and " to " in n):
            return "retarget", text  # "send this to X instead" names a place, not an end
        # A send phrase counts when it IS the turn or opens it; "whether to send
        # it" and "ready to send" are talk about sending, not the word.
        if any(n == p or n.startswith(p + " ") for p in SEND):
            return "send", ""
        if any(n == p or n.startswith(p) for p in CANCEL):
            return "cancel", ""
        if any(n == p for p in HOLD) or n in ("no", "nope", "not yet"):
            return "hold", ""
    # A long turn that closes with a send phrase after a clause break: the words
    # before the break are content. "…, send it." yes; "whether to send it" no.
    m = _TRAILING.search(text)
    if m:
        return "send", text[: m.start()].rstrip(" ,.;:")
    return "content", text


class OpenMessage:
    def __init__(self, destination: dict):
        self.destination = destination  # {"kind": "agent"|"note", "sessionId"?, "name"}
        self.text = ""
        self.last = ""
        self.since = time.monotonic()
        self.asked = False
        self.words = 0

    @property
    def name(self) -> str:
        return self.destination.get("name") or "the agent"

    def append(self, fragment: str) -> bool:
        """Append a transcript fragment, dropping the overlaps the STT re-emits
        (a fragment that repeats the last one, or extends it). Returns whether
        anything new was added."""
        f = fragment.strip()
        if not f:
            return False
        nl, nf = _norm(self.last), _norm(f)
        if nl and (nf == nl or nl.endswith(nf) or nf in nl):
            return False
        if nl and nf.startswith(nl):
            self.text = (self.text[: len(self.text) - len(self.last)].rstrip() + " " + f).strip()
        else:
            self.text = (self.text + " " + f).strip()
        self.last = f
        self.since = time.monotonic()
        self.asked = False
        self.words = len(self.text.split())
        return True
