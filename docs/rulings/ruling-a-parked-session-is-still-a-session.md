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

**Tapping a parked row brings the conversation back as a normal session.**
(Ruled 10 Sep, second pass, after measuring the first: "when I click on an
Amber row that's been backgrounded, I want it to be foregrounded.") Measured on
a scratch session: after the left arrow the conversation IS the background job.
Typing in the original terminal after Esc writes to the job's transcript, which
receives the whole history on the job's first use; the original file is closed
at its `continued-in` record. `claude --resume <original id>` still works and
silently forks a stale branch. `claude stop <8-char job id>` then
`claude --resume <job id>` keeps every word and yields one ordinary process.

So Go to Agent on a row waiting at the agent view does that, in order, and the
rest of the app never learns a special case: if the job is busy, raise the
window and say it is working; otherwise stop the job, end the original's empty
agent-view shell (Ctrl+C twice, SIGTERM if ignored, a refusal card if it
survives), and resume through the ordinary revive path, under the app's own
tmux pane. The id resumed is the job when its transcript carries the history,
the origin when it does not (a job stopped before first use, which is what the
hand fix of 10 Sep 6:10 did to 54acd236). The first cut of this rule pressed
Esc on the agent view instead; it worked and left the app on a background
session it would never type into, so it was replaced.

**A continuation is the same conversation.** Claude Code writes
`{"type":"continued-in","continuedInSessionId":…}` at the end of the old
transcript. The app follows it (`SessionLineage`): the origin's directory is the
hub, a continuation's directory is a symlink to it, and the hub lists every
member's turns and pages together. The grid shows one row for the family.

**The app never ends, restarts, or types into a session unasked.** The tap on a
parked row is the ask, and what it does is written above. Killing a helper,
sending `/exit`, and raising a tab by hand were all done this morning before the
rule existed; none of them is the rule.

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
