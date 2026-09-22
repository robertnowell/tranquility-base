"""What may reach a synthesizer.

The app's SpokenTextSanitizer, ported: identifiers are said as words, never
spelled. A uuid is "an identifier", a hash "a commit", a path "a file path", a
URL "a link", a 24+ character token "an identifier", code "some code". This runs
on everything the manager itself speaks through Gradium; the app applies its own
copy to what it speaks in a session's voice. Nothing that looks like an id is
ever read aloud, from any path.
"""

import re

RULES = [
    (re.compile(r"```[\s\S]*?```"), "some code"),
    (re.compile(r"`[^`]+`"), "some code"),
    (re.compile(r"https?://[^\s]+"), "a link"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "an identifier"),
    (re.compile(r"\b(?=[0-9a-f]{7,40}\b)(?=[a-f]*[0-9])[0-9a-f]{7,40}\b"), "a commit"),
    (re.compile(r"(?:~|\.{1,2})?/[\w.\-]+(?:/[\w.\-]+)+/?"), "a file path"),
    (re.compile(r"\b(?:[\w.\-]+/)*[\w\-]+\.(?:swift|ts|tsx|js|jsx|py|rb|go|rs|java|kt|c|h|cpp|json|ya?ml|toml|md|sh|sql|html|css)\b"), "a file"),
    (re.compile(r"\b[A-Za-z0-9_\-]{24,}\b"), "an identifier"),
    (re.compile(r"\b[a-z0-9]{8}\b(?=[^a-z]|$)(?<![a-z]{8})"), "an identifier"),  # an 8-char id prefix like 0616f4aa
    (re.compile(r"\b[a-z]+(?:[A-Z][a-zA-Z0-9]*){1,}\b"), "a variable"),
    (re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+){1,}\b"), "a variable"),
    (re.compile(r"\*\*([^*]+)\*\*"), r"\1"),
    (re.compile(r"(?:^|\s)#{1,6}\s+"), " "),
]
# Brevity is the prompt's job, not this function's. A thirty-word cut here
# took the last sentence off the manager's own capabilities line ("Say start an
# agent." was never spoken, 22 Sep) while the panel displayed it in full, so
# what was heard and what was shown disagreed. Ruled 09 Aug and again today:
# nothing truncates speech that is also displayed.


def spoken(text: str) -> str:
    out = text
    for rx, rep in RULES:
        out = rx.sub(rep, out)
    out = re.sub(r"\s+,", ",", re.sub(r"\s+", " ", out)).strip()
    return out
