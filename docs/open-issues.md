# Open issues — voice dispatch

Live tracker. Nothing gets closed here without evidence: a log line, a query, or a
test. Ordered by how much damage the bug does, not by how easy it is.

Companion to `docs/state-machine.html`, which maps every state against every input.

---

## 1. Headless sessions flood the queue — ROOT CAUSE OF THE "SAME MESSAGE" LOOP

**Status:** open. This explains three separate symptoms that looked unrelated.

`content-engine` is a launchd job running `claude -p`. **Every run is a new session
id**, so supersession — which collapses older turns *within a session* — never fires.
Ten runs produce ten unread rows carrying near-identical summaries.

That is why:

- dismissing the announcement left the count unchanged (other rows remained),
- pressing again replayed "the same message" (a different row, same text),
- the count said 2 while only 1 row was genuinely unread at the moment of the query.

There is no tab to open and no session to answer, so these should never be announced.

**Why it is not already fixed:** the hook filter was removed on purpose. Two attempts
were wrong — `$PPID` is not reliably the claude process, and walking the ancestry
crosses the session boundary — and both silently dropped *real* turns. The hook is
the one place where being wrong is unrecoverable.

**The fix:** the hook now records its own controlling terminal on every row. Plumb
that field into the events table and filter at selection time, where a wrong answer
costs a query and the evidence stays on disk. Do not put the decision back in the
hook.

---

## 2. Ambient surfacing does not fire when the panel is hidden

**Status:** open, partially built.

`surfaceArrival` exists and the gate is consulted, but arrivals are not reaching the
screen in practice. Two candidate causes, untested:

- the panel is `.hidden`, and the refresh only runs when the count *changes* — a
  count that was already 2 stays 2, so nothing repaints;
- issue 1 keeps the count permanently non-zero, so a genuine new arrival never looks
  like a change.

Fix 1 first, then re-test this. They may be the same bug.

---

## 3. Repeated ⌃⌥ replays the item you are listening to

**Status:** open.

Stopping an announcement reverts it to unread (correct — half an announcement is not
read). It is also the newest, so the stack hands it straight back. With one item
waiting, the result is a loop with no way past it.

**The fix:** remember the event stopped by the most recent press and exclude it from
the *next* selection only. If there is nothing else, say so rather than replaying.
Not a status change: it must stay unread.

---

## 4. Slow transcription looks like a hang

**Status:** open.

A 27-second recording took long enough that the panel sat on "Transcribing your
reply…" with no feedback. It completed — 401 characters — so nothing was lost, but
there was no way to know that.

**The fix (Wispr's, and it is the right one):** after ~20s say "taking longer than
usual, your audio is safe", with retry and cancel. The audio is already durable on
disk before any network call, so that promise is true today and just unstated.

---

## 5. Escape is dead in three states

**Status:** fixed by the state machine below, needs verifying in use.

`isBusyOnScreen` tested `isRecording` (the Reply-button flag) and never `isListening`
(the hold-gesture flag), so Escape did nothing during the most common interaction in
the app. Also dead in settings and while idle.

---

## 6. ⌃⌥ while the microphone is open

**Status:** open.

Starts an announcement into a live mic — it would record itself. Should be ignored
while capturing. `PanelState.isCapturingAudio` now exists to express this; the guard
is not wired in yet.

---

## 7. ⌥ with nothing to reply to

**Status:** open.

Records and transcribes a reply that has nowhere to go, then fails. Refuse at the
gesture. `PanelState.canStartReply` exists; not wired in yet.

---

## 8. ⌃⌥ during the send window

**Status:** needs a decision, not a fix.

Today: a new announcement starts and the countdown keeps running, so the reply sends
while a new summary plays. Either the countdown wins and the tap is ignored, or the
tap cancels the send. No obviously correct answer.

---

## 9. Summaries invent numbers

**Status:** open.

A summary read "ninety-nine rendering tests pass" when there were 65. The model was
told to ground everything in the final message; numbers are the worst thing for it to
embellish because they sound exactly like the detail you would trust.

**The fix:** the sanitizer is the right layer — strip or flag digits that do not
appear in the source message, the same way it already strips identifiers.

---

## 10. Before pushing

- `model-calls.jsonl` grows without bound and holds full session content. Needs
  rotation and a cap.
- Clicky's MIT copyright belongs in a NOTICE: the hotkey monitor and the PCM
  converter are adapted from it. Licence obligation, not courtesy.

---

## In progress: the state machine

Five independent booleans (`isRecording`, `isListening`, `isSpeakingNow`,
`awaitingConfirm`, `isIdle`) replaced by one `PanelState` with one case per state.
Every guard derives from it and every transition is logged as
`state: speaking -> listening  (recording started)`.

This is what makes issues 5, 6 and 7 answerable in one place instead of three, and it
is why they were invisible: nothing in the code said those flags were describing the
same idea.

Done: the enum, the logged transition, guards for Escape, ambient surfacing, audio
capture and reply-eligibility. Remaining: wire 6 and 7 into the gesture handler, and
delete the last of the booleans.
