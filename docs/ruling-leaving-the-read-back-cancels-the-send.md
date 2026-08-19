# Ruling — leaving the read-back cancels the send

**Ruled 18 Aug 2026.** In the user's words:

> During the read-back state, if I hit Option-Option to speak, the previous
> utterance will still send… If I hit Option-Option again, I mean, don't delete
> the audio, right? Don't delete the transcription. It can still live in my past
> utterances, but don't send it to the agent. If I hold Option or if I do
> Option-Option, it should effectively be the same as hitting Don't Send and
> then doing Option-Option.

## What was happening

`app.log`, 18 Aug, one real occurrence:

```
22:39:01  state: transcribing -> pendingSend  (undo window open)
22:39:02  ⌥ tap: armFirstOfPair in pendingSend
22:39:02  ⌥ tap: startListening in pendingSend
22:39:02  state: pendingSend -> listening  (recording started)
22:39:05  state: listening -> idle  (countdown completed, user door)
22:39:05  earcon: dropped dispatched — mic is open
22:39:07  confirmAndSend -> dispatched(text: "So a critical thing here…")
```

Three seconds of the replacement utterance were already recorded when the
replaced one went out. The app noticed enough to suppress its own send earcon
("mic is open") and sent anyway.

## Why

The countdown **is** the send. `StatusHUD.render()` hands the send closure to a
one-shot `Timer` *by value*, so clearing `onCommitSend` stops nothing; only
invalidating the timer does. `.pendingSend` legally admits three states —
`.result`, `.transcribing`, `.listening` — because re-recording during the
window has to be possible. Exactly one of the paths reaching them cancelled the
send, so the other two were the same incident waiting on a different press.

`OptionTapDecision` was correct throughout: `.startListening` is the right
decision for ⌥⌥ in the read-back. The bug was in the side effects `main.swift`
performs for that decision — the split that file's own comment warns about
("this handler owns the side effects only"). The decision had been extracted and
asserted; the effects had not.

## The rule

**Leaving `.pendingSend` for anything that is not another `.pendingSend` cancels
the send.** It is a property of leaving, not of whichever caller happened to
leave, so it lives in the doors:

- `PanelState.releasesPendingSend(movingTo:)` — the decision, in Core, asserted
  by `ReadbackDoorTests`. Its last test ties this table to `admits`: every legal
  exit from the read-back must release the send, so widening `admits` later
  cannot silently re-open the hole.
- `StatusHUD.leaving(for:)` → `releasePendingSend(for:)` — the doing, run by
  both `transition` and `forceTransition` before the state moves.

All four existing exits (`commitPendingSendNow`, `cancelPendingSend`,
`endCapture`, and the countdown's own completion) already invalidate the timer
before they transition, so the door is a no-op on every one of them. A commit
can never become a cancel: a commit has nil'd the timer by the time it moves.

## Ordering — the cancel happens BEFORE the microphone

`main.swift`'s ⌥ tap handler cancels the pending send *before* `recorder.start()`,
which deliberately reads against the 10 Aug rule two comments below it
("nothing is mutated until the microphone is actually recording").

That rule protects a waiting agent you could **lose** to a failed open. This is
the opposite kind of mutation: you asked for these words not to be sent, and a
microphone that fails to open is not a reason to send them. A failed open lands
on the mic-failure card with the transcript discarded — kept in past utterances,
out of the sendable set — which is where Don't send leaves it too. The hold path
(`.replyBegan`) has always used this order.

## What "discarded" costs you — nothing you wanted

`Coordinator.cancelSend` sets `status = .discarded` and returns any attachments
to the chips. The row and its transcript survive, so it stays in past utterances
and stays replayable; only the audio *file* is reapable, by the 72-hour
retention sweep, exactly as a confirmed send's is.

## Also fixed by the same press

`replyGeneration += 1` in the tap path. It is not the fix and cannot be — 
`send(utteranceId:)` reads the generation when the timer *fires*, so it never
catches a countdown. What it catches is the sibling case one state over: ⌥⌥
during `.transcribing`, which also admits `.listening`, where the replaced
transcription would otherwise finish and open a read-back for the old words
while you are already speaking the new ones.

## Evidence

- `ReadbackDoorTests` (Core, 5 tests) — the decision, including the
  admits/releases property. Mutation-checked: reintroducing the `.listening`
  hole fails three of the five and leaves the two unrelated ones green.
- `selfTestReadbackDoor` (panel drill, runs on every deploy) — the effect,
  through the door the gesture uses rather than through `cancelPendingSend`,
  which is the one door that was never broken. `selfTestPendingSend` could not
  have caught this, and did not.
