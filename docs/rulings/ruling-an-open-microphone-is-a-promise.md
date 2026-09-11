# Ruling: an open microphone is a promise

Ruled 10 Sep 2026, by the user, against a measurement: a 5m08s push-to-talk
dictation (capture `46ef15586ba4ff36`, 17:31:35–17:36:43 PDT, build 0.3.1139)
was deleted at release — audio unlinked, streamed transcript dropped with the
socket, no Recents row — because one keystroke somewhere on the system during
the hold had set `ReplyGestureMachine.disqualified`. The pill said Listening
the whole time. Zero log lines were written at the moment it was condemned.
Incident write-up: the "lost dictation" page in HQ (session 8d40f488).

## The rule, in the user's words

> "If the mic is open and there's speech, we should respect that speech. We
> should just not delete anything that has been written. We shouldn't throw
> away the audio, especially if it's longer than 10 seconds or has speech. We
> cannot lose transcriptions. That's the fundamental guarantee: you should
> trust that that mic means you're being listened to. If the mic is open and
> some utterance is uttered, then that utterance is respected — it's saved and
> transmitted, with a readback opportunity to cancel if you want."

And, on the workaround the incident page offered ("use ⌥⌥ hands-free for
anything over 30 seconds"): **"That's not a user-facing solution."**

## What it decides

1. **A committed hold is deaf to the keyboard.** `sawOtherInput` disqualifies a
   gesture only in `pending` and `armed` — the window the guard was written
   for, where bare ⌥ is the start of a typed ⌥-character and interference
   arrives within tens of milliseconds. Once `holdElapsed` has committed the
   recording, a keystroke, a click or a second modifier means nothing to the
   gesture, and release is always `endReply`. The words go through the
   ordinary path: transcribe, read back, Don't-send. The user decides, not a
   keystroke. `ReplyGestureMachine` has no abort-reply effect any more.
2. **Deletion needs a reason, and "abandon" is not one.** `LiveAudioCapture
   .abandon` keeps the file — still `.wav.live`, exactly what a process death
   leaves — when the capture ran past ten seconds or the recorder's peak
   cleared the silence floor. The arm-window tap-abort that instant-arm was
   built on (E2) is milliseconds of room tone and is still removed.
3. **A kept file is reachable.** `QueueStore.reconcileOnBoot` adopts orphan
   live captures of ten seconds or more into `.recorded` rows, dated by the
   file, so they appear in the recent-audio pane with Play and Retry. Before
   this, an orphan live file — whether a death or an abandon left it — sat
   invisible until the 72h reap deleted it: the durable copy existed and
   nothing could reach it. Not transcribed unasked (13 Aug ruling stands).
4. **The condemning moment is on the record.** `HotkeyMonitor` logs stray
   input during an arm window or a committed hold with the key code and the
   elapsed hold time, once per hold.

## What this supersedes

- `docs/instant-arm.md` E1's "disqualification mid-reply → abortReply at
  release" row. Amended in place.
- The `HotkeyMonitor.Transition.replyAborted` leg is now reachable only from
  the launch self-test's E4 abort drill, and is kept for it.

## What stays open

- The streamed transcript still lives only in the AssemblyAI session object
  until a clean close. With rule 1 there is no path that closes it unclean
  from a gesture; a process death still loses the partials and recovers from
  the file. Making the partials durable as they arrive is the remaining half
  of "never lose a transcript", and is not built here.
- "Our transcription needs to be faster" (same dictation). AssemblyAI
  streaming has been out of funds since 4 Sep, so every capture takes the
  ~3s file path; that is a billing fact, not a code change.
