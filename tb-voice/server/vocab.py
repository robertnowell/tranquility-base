"""The manager's vocabulary, typed (hf-26).

Ruled 23 Sep: strings are parsed once, at a boundary, into these types, and
every decision after that is made on the types. Before this, who said a line
was "you" or a display name, its status was one of four bare strings, an
intent was Jev's label, a compose verdict was a word, and the manager found an
intent's handler by building a method name from the label. A typo in any of
them was not an error, only a branch that silently never ran.

Boundaries, and nowhere else:
- Jev's answers become an Intent or a Verdict (parse_intent, parse_verdict).
- A Line becomes the strings Jev and the brain read (Line.jev_who, jev_status).
- A Line becomes the `said` event the Mac records (Line.said_fields).
- Wire frames and tool names are WireKind and Tool (wire.py).
An unknown value at a boundary is logged loudly and mapped to the one safe
member (Intent.NONE, Verdict.CONTENT); it never flows on as a string.
"""

from dataclasses import dataclass
from enum import Enum

from loguru import logger


class Role(Enum):
    USER = "user"          # the developer
    MANAGER = "manager"    # Tranquility itself
    AGENT = "agent"        # a coding-agent session speaking through the app


class LineKind(Enum):
    TALK = "talk"            # the developer said it, not to the manager
    COMMAND = "command"      # the developer said it to the manager
    DICTATION = "dictation"  # the developer's words into an open message
    SPOKEN = "spoken"        # said aloud by the manager or an agent
    ACTION = "action"        # something the manager did (typed into an agent)


@dataclass(frozen=True)
class Line:
    role: Role
    kind: LineKind
    text: str
    speaker: str = ""                # a display name for agents; empty otherwise
    target: str | None = None        # for ACTION: the agent's session id
    target_name: str | None = None   # and the name it was introduced by

    # -- the views other systems read, derived here and only here ---------------

    @property
    def jev_who(self) -> str:
        """Jev's prompt says 'you' is the developer and other names speak."""
        if self.role is Role.USER:
            return "you"
        if self.role is Role.MANAGER:
            return "Tranquility"
        return self.speaker or "agent"

    @property
    def jev_status(self) -> str:
        """Jev's prompt: 'acted' or 'spoken' was already handled."""
        return _JEV_STATUS[self.kind]

    @property
    def jev_text(self) -> str:
        if self.kind is LineKind.ACTION:
            return f"(typing into {self.target_name or 'an agent'}) {self.text}"
        return self.text

    def said_fields(self) -> dict:
        """The `said` event's payload: typed values, sent as their names."""
        out = {"role": self.role.value, "kind": self.kind.value, "text": self.text}
        if self.speaker:
            out["speaker"] = self.speaker
        if self.target:
            out["target"] = self.target
        if self.target_name:
            out["target_name"] = self.target_name
        return out


_JEV_STATUS = {
    LineKind.TALK: "silent",
    LineKind.COMMAND: "acted",
    LineKind.DICTATION: "dictated",
    LineKind.SPOKEN: "spoken",
    LineKind.ACTION: "acted",
}


def line_from_transcript(who: str, status: str, text: str) -> Line:
    """Local mode only: transcript.md stores the Jev view; read it back."""
    kind = {v: k for k, v in _JEV_STATUS.items() if k is not LineKind.ACTION}.get(status, LineKind.TALK)
    if who == "you":
        return Line(Role.USER, kind, text)
    if who == "Tranquility":
        if kind is LineKind.COMMAND:  # "acted" by the manager is an action
            return Line(Role.MANAGER, LineKind.ACTION, text)
        return Line(Role.MANAGER, LineKind.SPOKEN, text)
    return Line(Role.AGENT, LineKind.SPOKEN, text, speaker=who)


class Intent(Enum):
    INVITE_NEXT = "invite_next"
    RUNG_GOAL = "rung_goal"
    RUNG_FINDINGS = "rung_findings"
    RUNG_SOLUTION = "rung_solution"
    RUNG_WHY = "rung_why"
    CUSTOM = "custom"
    SEND_MESSAGE = "send_message"
    START_AGENT = "start_agent"
    TAKE_NOTE = "take_note"
    SUMMARIZE_RECENT = "summarize_recent"
    TEACH = "teach"
    SPEAK = "speak"
    MUTE = "mute"
    NONE = "none"


class Verdict(Enum):
    """What a turn is while a message is open (compose)."""
    CONTENT = "content"
    SEND = "send"
    HOLD = "hold"
    CANCEL = "cancel"
    RETARGET = "retarget"


def parse_intent(label: str | None) -> Intent:
    try:
        return Intent(label)
    except ValueError:
        logger.error(f"UNKNOWN INTENT {label!r} from the classifier; treated as none")
        return Intent.NONE


def parse_verdict(label: str | None) -> Verdict:
    try:
        return Verdict(label)
    except ValueError:
        logger.error(f"UNKNOWN VERDICT {label!r} from the classifier; treated as content")
        return Verdict.CONTENT
