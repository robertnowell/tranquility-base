# The capture is a strip under the card, not a screen instead of it

Ruled 09 Aug 2026, spoken. RULED, NOT BUILT. Written down per CLAUDE.md rule 4
because it changes the same surface `docs/rulings/ruling-capture-returns-to-its-card.md`
describes and **supersedes most of that doc's problem** — a card that is never
taken down needs no machinery to give it back.

## The ruling, in the user's words

> "We can stay on the reading screen while it's recording, and you could just
> stay there, right? The next screen can just be a little announcement below,
> the same height as the spoken screen, and it can be a preview of what's being
> sent. It can be the read-back state right there on the same screen as the
> read-back, but not the read-back. The read-back can be on the same screen as
> the main text, right? The main reply. At the bottom, it gives you the spoken,
> so you can start speaking, but you can still see the current state."
>
> "Now, what happens if you control? I think what happens is it advances text,
> but it doesn't speak because you're talking, right? It shouldn't, so it just
> appears basically as read. If you end the recording, then it stays in its
> current state. If you are in the recording and then hit control, it'll speak,
> right?"
>
> "The next screen, you can bring up the voice, not even tray, right? Below
> extension, whenever you hit Option."

One sentence: **speaking to an agent does not cost you the thing it said.** The
reading card stays on screen for the whole capture; the capture is a strip
beneath it.

## What today does, and why this is a change

Every capture entry point rebuilds the face wholesale, so the reply you are
answering disappears the instant you press the key:

| Entry | Line | What it does to the card |
|---|---|---|
| `showArming` | `StatusHUD.swift:108` | `face = Face(listeningTarget:)` — card gone, prior face stashed for revert |
| `showListening` | `StatusHUD.swift:131` | `face = Face(listeningTarget:)` — card gone, **stash cleared** |
| `showPendingSend` | `StatusHUD.swift:201` | `face = Face(title:body:placardOverride: READBACK…)` — card gone, replaced by the quoted transcript |

Three different faces in sequence, each replacing the last, for one continuous
act. The user is answering a reply he can no longer see, and the READBACK card
asks him to check words against a message that is no longer on screen.

## What follows without interpretation

**1. A capture augments the face; it does not replace it.** `.arming`,
`.listening` and `.pendingSend` stop constructing a fresh `Face`. They set a
strip *on the existing face* — one new optional field, rendered by `render()`
below the body, in the spirit of 3a's one-paint-funnel rule and of the ink
ruling ("the ink becomes part of the face"). The card's title, topic, body and
ink are untouched for the entire capture.

**2. The states stay real.** This is a face change, not a state change. The
legality table (`PanelState.admits`), `ownsStage`, `isCapturingAudio` and
`allowsAmbientSurface` are unaffected: a capture still owns the stage and still
refuses ambient arrivals. What changes is only what a capture *paints*. A
session that implements this by deleting `.listening` or by making the strip a
new `PanelState` has misread it, exactly as with the collapsed strip.

**3. One slot, three phases, one height.** Arming, listening and read-back are
the same strip at the same height — "the same height as the spoken screen",
i.e. the listening pill's present geometry. Within a capture **nothing moves**:
the strip's contents change, its box does not. This is the same property the
collapsed-strip ruling protects for the lamps — a surface whose shape is
constant and whose contents are the only variable can be read at a glance.

| Phase | The strip shows |
|---|---|
| `.arming` | the listening pill's geometry in the faint treatment (unchanged from `instant-arm.md`) |
| `.listening` | destination + level meter + the preview of what is being sent |
| `.pendingSend` | the read-back words + the countdown bar, **in the same slot** |

**4. The read-back loses its card.** "The read-back can be on the same screen as
the main text… the main reply." `showPendingSend` no longer takes the stage
visually; the READBACK placard, the quoted transcript and the countdown all
render in the strip, under the reply they answer. Checking the transcript
against the message becomes possible for the first time.

**5. The strip is a preview of what is being sent, live.** "It can be a preview
of what's being sent." The streaming partial transcript
(`AssemblyAIStreaming.swift`) belongs here — the strip is what proves the app
heard you, which is `showListening`'s stated whole job, now doing it without
spending the card.

**6. ⌃⌃ during a capture advances the text and does not speak it.** Today both
gestures are refused outright while the mic is open —
`guard !hud.isCapturingAudio` at `main.swift:903` (⌃⌥) and `main.swift:1060`
(⌃⌃). The ruling splits that guard in half: the *audio* half stands (announcing
into a live mic records itself — the reason those guards exist), the *visual*
half is lifted. ⌃⌃ while recording walks the ladder, repaints the card at the
next rung, and paints it **fully inked** — "it just appears basically as read" —
with no TTS and no shimmer. `ladderIndex` advances normally.

**7. Ending the capture changes nothing on the card.** "If you end the
recording, then it stays in its current state." No rewind to the rung you
started on, no re-speak of what was advanced silently. The strip drops; the card
stays exactly where ⌃⌃ walked it.

**8. Every non-send outcome is now just "drop the strip."** The four outcomes in
`docs/rulings/ruling-capture-returns-to-its-card.md` §C — silence gate, Don't send, empty
transcription, lost address — no longer need a card restored, because no card
was taken. That ruling's `Face.spokenUpTo` / `paintInk` / `stashBeforeCapture` /
`restoreCardAfterCapture` design exists to give back something this ruling never
takes. **Do not build it and then undo it** (see the correction below — it is
indexed as BUILT and is not).

What survives from that ruling, undiminished, and should be built with this:
- **The PanelState still has to go back.** The face is intact; the *state* must
  still force-transition from `.listening`/`.pendingSend` to the card's state.
  The stash shrinks to a state, not a state-plus-face.
- **§D stands, verbatim: no outcome reopens the microphone on its own.**
  `cancelPendingSendTapped` (`StatusHUD.swift:270`) still passes
  `restartListening: true`. It must pass `false`.
- **§C's lost-address rescue stands** — transcribe anyway, copy to the
  clipboard, say so. The words are the user's.
- **§E stands**: a capture begun from the grid has no card to sit under, so the
  strip is the whole panel, exactly as today.

## Open — do not guess these

1. **"If you are in the recording and then hit control, it'll speak, right?"**
   This contradicts item 6 two sentences earlier. The reading that makes the
   passage coherent is *out of* the recording — you ended the capture, the card
   is standing at the rung ⌃⌃ walked it to silently, and the next ⌃⌃ speaks
   normally. That is a reconstruction, not a ruling. **Needs Robert.**

2. **The last fragment did not survive transcription.** "You can bring up the
   voice, not even tray… Below extension, whenever you hit Option." The
   recoverable part — the ⌥ path raises the strip *below*, with no separate
   tray or screen — is item 1 restated for `.arming` and is treated as
   confirming, not extending. "Tray" and "extension" are unrecovered.
   **Needs Robert.**

3. **Which way the panel grows.** The strip appearing makes the panel taller.
   The card must not move when it does, which means the resize anchors at the
   top and grows downward. `resizeToFit` + `position` currently place the panel
   as a floating card; whether that already holds the top edge is unmeasured.
   Measure before ruling (rule 4).

4. **⌃⌥ during a capture** is deliberately not ruled here. "Control" in this
   app's vocabulary is ⌃⌃ (`.controlDoubleTapped`); ⌃⌥ is spoken as "Control
   Option" and means home-first, which has nothing to advance. Its
   `isCapturingAudio` guard at `main.swift:903` stays as it is until ruled
   otherwise.

## Evidence this needs (rule 7)

Panel behaviour, so `swift test` says nothing about it. Launch drills:

- `showListening` entered from `.speaking` leaves `face.title`, `face.body` and
  the ink byte-identical; only the strip is added.
- The card's frame origin is unchanged across `.arming` → `.listening` →
  `.pendingSend` — one slot, no movement.
- ⌃⌃ during `.listening` repaints the card at the next rung with the ink full,
  the shimmer unarmed, and `speech.speak` never called.
- Ending a capture leaves the card at the rung ⌃⌃ walked it to, not the rung it
  started on.
- Don't send leaves `recorder.isRecording == false` (inherited from §D, still
  unbuilt).
- A capture begun from `.idle` still paints the strip alone.

## Correction to docs/README.md

`docs/rulings/ruling-capture-returns-to-its-card.md` is indexed **BUILT `d106206`**. That
commit added the doc and nothing else — `git show --stat d106206` is one file,
170 insertions, `docs/` only. None of the design ships: no `spokenUpTo`, no
`paintInk`, no `stashBeforeCapture`, no `restoreCardAfterCapture` anywhere in
`Sources/`, and `cancelPendingSendTapped` still restarts the microphone. The
index entry is corrected to RULED, NOT BUILT in the same commit as this file —
a false BUILT is worse than no index, and it sat on the one doc this ruling
most needed to be true about.

## What this does not touch

Core, the announcement path, the away-channel law, speech, the grid, and the
collapsed strip. The reading card gaining a strip is a face, not a voice.
