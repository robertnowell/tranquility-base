# A parked session is still a session

Ruled 10 Sep 2026, between 6:01 and 7:10 AM, on "Hub design and organization".

## The incident

Robert pressed the left arrow on an empty prompt. That is a Claude Code
feature: it sends the session to the background and opens the agent view.
Claude Code does it by carrying the conversation on under a new session id in a
helper process with no window, and from then on `claude agents --json` lists the
helper and hides the session.

Three things followed in the app, and they were one missing rule:

1. The grid drew one blue row for the helper, wearing the session's name. Go to
   Agent looked for the helper's pane, found none, tried an ownership transfer,
   and the resume guard refused because the helper's pty host held the id. Card:
   "already running elsewhere and its window could not be raised."
2. Discuss on one of the session's own reports offered a revive, and the revive
   guard refused it, because the real process was alive in its tmux pane.
3. The helper ran one turn, the app filed it under the new id, and the hub split:
   days of history under the old id, one turn under the new one, same name.

Robert, twice: doing anything by hand is not the solution. The question is how
Tranquility Base should work.

## The rules

**A row is a session, never the helper standing in for it.** (PR #343.) The
app reads Claude Code's own per-session files (`~/.claude/sessions/<pid>.json`).
A background job that a live interactive session has parked
(`parkedJobId == jobId`) is dropped from the live list; if the CLI omitted the
session, the session stands in, reported as waiting at the agent view. Its pane
comes from its own file. The lamp is amber with "backgrounded in the agent
view"; a typed reply is refused, because the terminal is showing the agent
view's task box and the words would start a new session.

**Go to Agent lands on the conversation, not on the agent view.** When the row
is waiting at the agent view, Go to Agent raises the session's own tab and, if
the pane is showing the agent view, presses Esc there, which Claude Code's own
screen text says returns to the conversation. The card says what it did. If the
screen is not the agent view, nothing is typed.

**A continuation is the same conversation.** Claude Code writes
`{"type":"continued-in","continuedInSessionId":…}` at the end of the old
transcript. The app follows it (`SessionLineage`): the origin's directory is the
hub, a continuation's directory is a symlink to it, and the hub lists every
member's turns and pages together. The grid shows one row for the family.

**The app never ends, restarts, or types into a session on its own initiative.**
It shows what is running, takes you to it, and does the one keystroke the screen
itself asks for. Killing a helper, sending `/exit`, and raising a tab by hand
were all done this morning before the rule existed; none of them is the rule.

## Facts that decided it

- Documented: the left arrow on an empty prompt backgrounds the session and
  opens agent view. Not Remote Control.
- The agent view's own text: "Your conversation moved to the background. enter
  opens it. esc returns to it." Measured 10 Sep: Esc showed the conversation
  (6:16 screenshot); Enter restarted the helper, which then ran a turn (6:17 to
  6:18).
- The old transcript's last record was `continued-in`; the new transcript has
  no pointer back. The link exists in exactly one place.
- `~/.claude/sessions/8805.json` carried `parkedJobId` and the tmux pane the
  whole time. The app had been reading that directory for other reasons since
  September.
