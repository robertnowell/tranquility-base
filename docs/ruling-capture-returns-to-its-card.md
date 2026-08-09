# A capture that sends nothing returns to the card it interrupted

Ruled 08 Aug 2026, from two incidents in one evening. Written by a session that
could not apply it: `Sources/TranquilityApp/` was held by another session at the
time (CLAUDE.md rule 5). The diagnosis is measured, not argued — every claim
below cites `app.log`.

## The ruling, in the user's words

> "If I start talking and then I stop talking — i.e. recording — and if either no
> text is detected or I hit Don't send, it should go back to the agent and update
> to the previous state that it was in … it should be in the read state and on
> whatever depth it was producing, instead of going back to the recorder."
>
> "It shouldn't have automatically gone back to that and recorded again."
>
> On the lost-address card: "it should definitely copy the script."

One sentence: **the card you were on is where a capture returns when nothing was
sent** — same rung, same ink — and no outcome silently reopens the microphone.

## Incident 1 — the ⌥⌥ that read as a crash (20:21:28)

Reported as a crash. It was not one: pid 31906 spans the whole window, the log is
unbroken, there is no relaunch line and no report in `~/Library/Logs/DiagnosticReports`.

```
20:21:21  highlight rendered bright=437/437      ← SOLUTION rung finished; card fully inked
20:21:28  ⌥ tap: no meaning in speaking(...)     ← first tap of the ⌥⌥
20:21:28  ack: held on → speaking -> arming      ← second press armed instead of tapping
20:21:29  ack: released                          ← ~778ms after key-down
20:21:29  arm reverted: tap or chord
20:21:29  highlight upTo=0→0 of 437              ← THE INK CLEARED
20:21:33  return-to-grid: card done, no gesture for 4s
```

Three defects, stacked:

1. **The revert repaints a finished card as unread.** `revertArming`
   (`StatusHUD.swift`) restores the stashed `state` and `face`, then calls
   `render()` — whose `.speaking` arm unconditionally runs `highlight(upTo: 0)`
   and `armBodyShimmer()`, because it assumes entering `.speaking` means a fresh
   card whose audio has not started. On a revert it is a *finished* card. The
   stash carries state and face; **the ink is not part of the face**, so it
   cannot be restored. That is the root cause, and it is an architectural leak:
   the file's own doc says "state + face is render()'s entire input", and the ink
   is the one rendered property that is applied outside that contract.

2. **A 778ms press meant nothing.** `endGesture` only classifies a tap when
   `duration < holdThreshold` (200ms); the hold path depends on `holdCheck`
   firing at +200ms. This press got neither. Not a one-off — **9 discards ≥200ms
   in one log** (305, 302, 305, 302, 298, 2100, 370, 330, 307ms), each a press
   that opened the microphone and produced nothing. This is the same dead band
   the 06 Aug 0.35→0.20 ruling was written to kill, and it is unfixed. The
   mechanism is not yet proven: `mic open +471ms after key-down` (vs the usual
   ~160ms) says the main queue was congested inside `openArmWindow`, but the log
   cannot distinguish "holdCheck fired and was refused" from "holdCheck was
   cancelled before firing". **Instrument before ruling** (rule 4): log every
   `holdCheck` firing and cancellation with the wall-clock press duration, then
   read one evening of real presses.

3. **⌥⌥ is unreachable once the second press exceeds 80ms.** The double-tap needs
   two `.optionTapped` events, but a press that survives the 80ms arm grace and
   then aborts emits `.abortArm` and no tap at all. `HotkeyMonitor.swift`'s own
   comment assumes "those taps run 50–100ms"; this one ran ~780ms.

## Incident 2 — Don't send lost the address and reopened the mic (21:44)

```
21:44:22  hands-free: listening locked
21:44:25  listening -> transcribing
21:44:28  routing: replyTarget resolved: session=bea35260… label=tranquility-base
21:44:28  transcribing -> pendingSend  (undo window open)
21:44:30  pendingSend -> listening  (recording started)   ← Don't send RESTARTED the mic
21:45:15  send: recording has no captured address; refusing
21:45:15  transcribing -> result.failed
```

4. **"Don't send" restarts recording, by design, and the restart has no address.**
   `cancelPendingSendTapped` calls `cancelPendingSend(restartListening: true)`,
   whose closure calls `hud.showListening(...)` + `recorder.start()` — but never
   re-captures `recordingTarget`. Forty-five seconds later the send refused with
   "This recording lost its address. Audio kept; nothing sent." The comment
   defending the restart — "you stopped it because the words were wrong, so the
   next thing you want is to say them again" — is now superseded: doubt about the
   words is not an instruction to say them again.

5. **The lost-address card strands the words.** It refuses *before*
   `submitReply`, so no transcript exists and `copyTranscriptToClipboard` (which
   the `tabNotFound` / `targetGone` rescues already use) has no `utteranceId` to
   work from. The audio is kept and the user gets nothing they can use.

## The design

**A. The ink becomes part of the face.** Add `Face.spokenUpTo: Int?` — the
DISPLAY-space cursor, `nil` meaning "unspoken baseline". Extract the painting
half of `highlight(upTo:)` into `paintInk(displayCursor:)`; `highlight(upTo:)`
maps spoken→display, stores the result in `face.spokenUpTo`, then paints.
`render()`'s `.speaking` arm becomes `paintInk(displayCursor: face.spokenUpTo ?? 0)`
and arms the shimmer only when that cursor is 0. Store the *mapped* cursor, not
the spoken index: `currentSpoken` may differ by the time a face is restored, and
re-mapping a stale index is how the ink would come back in the wrong place.

Every `face = Face(...)` resets it to `nil`, so fresh cards still start unspoken.
Fixes defect 1 structurally — any restore of any face restores its ink, because
the ink is in the face.

**B. The arm stash becomes a capture stash.** Rename `stashBeforeArming` →
`stashBeforeCapture`. Do not clear it when arming upgrades to listening
(`showListening` currently does). `showListening` takes the stash itself when
none exists — hands-free (⌥⌥) and the Reply button open a capture without ever
arming. Add:

```swift
@discardableResult
func restoreCardAfterCapture(because reason: String) -> Bool
```

which force-transitions back to the stashed state, restores the face (ink and
all), renders, consumes the stash, and returns false when there was no card.
`endCapture` must stop clearing the stash — it yields the stage, it does not
decide the outcome. The stash is dropped where a card genuinely should not come
back: painting the grid (`showIdle`), a new announcement taking the stage, and a
successful send.

**C. The four non-send outcomes all return to the card.**

| Outcome | Today | Ruled |
|---|---|---|
| Silence gate / nothing heard | `showIdleGrid()` | restore the card; carry the notice with `note(...)`, not a card |
| Don't send | restarts the mic | restore the card, mic stays shut |
| Transcription empty | result card | restore the card |
| Lost address | result card, words stranded | transcribe anyway, copy to clipboard, say so |

The "nothing heard" notice must ride `note(...)` rather than `flashNotice(...)`:
`flashNotice` belongs to idle and `transition` clears it on any non-idle state,
so a restored card would eat it. That keeps the current branch's ruling —
*the silence gate is a notice, not a card* — intact on top of this one.

For the lost address, transcribe the kept audio through the dictation path's
`store.captureAndTranscribe` and hand the text to the clipboard, then say
"Copied your words to the clipboard" instead of "nothing sent". The words are the
user's; losing the address is our fault, not theirs.

**D. No outcome reopens the microphone on its own.** `cancelPendingSendTapped`
passes `restartListening: false`. The `restartListening` flag survives only as
"the caller is already painting something" (its `endCapture` use); the restart
branch in main.swift's cancel closure is deleted.

**E. When there is no card to go back to**, a capture that started from the grid
returns to the grid, exactly as today. The HUD cannot build grid rows, so
`restoreCardAfterCapture` returning false is the host's signal to call
`showIdleGrid()`; the host also re-arms Ruling 14's dwell clock on a true, the
same way the `armAborted` path already does.

## Evidence this needs (rule 7)

`swift test` says nothing about any of it. Add launch drills:

- `revertArming` on a card inked to N restores it at N, not 0, and does not
  re-arm the shimmer.
- `showListening` entered from `.speaking` keeps the arm's stash rather than
  taking a second one over the arming face.
- `restoreCardAfterCapture` after a pendingSend returns the exact prior state,
  face, and ink; returns false with no stash.
- Don't send leaves `recorder.isRecording == false`.

The 21:50 drill fix landing in `StatusHUD.swift` right now — the pendingSend
drill standing its own card down so it stops wedging the panel — is the
precedent: a drill that holds the stage is a drill that breaks the app.
