# A recording must be on disk while it is still being spoken

Measured 08 Aug 2026. Written down per CLAUDE.md rule 4 — this reverses a stated
design decision, so it cites evidence rather than an argument.

## What was lost

Six recordings, between **23:06:50 and 23:12:43 PDT** (06:06–06:13Z in `app.log`,
which stamps UTC). Each one appears as a `state: … -> listening (recording
started)` with **no matching `listening -> transcribing`**:

| PDT | |
|---|---|
| 23:06:50 | `speaking -> listening` · `hands-free: listening locked` |
| 23:10:27 | same |
| 23:11:47 | same, twice |
| 23:12:08 | same |
| 23:12:43 | same |

The next successful transcription is 23:13:18. Nothing survived any of the six:
no row in `queue.sqlite`, no WAV on disk, no text. The user lost five or six
utterances in about fifteen minutes and could not get any of them back.

## What caused it

`scripts/relaunch.sh` runs from a parallel session, three times inside the
window — `args=[".../tb-clean/.../TranquilityApp", "--selftest-hud"]` at
23:09:56, 23:13:21 and 23:40:52. Every one of the six recordings started after
one relaunch and was still open at the next. With hands-free listening locked, a
capture stays open until the user taps to send, so a relaunch during that window
destroys however much has been spoken.

`Recorder` buffers PCM16 in memory for the length of the utterance and writes it
once, at key-up. Its header states the reasoning:

> Per-chunk write-ahead was [rejected because] the failures that actually happen
> are network and API ones, which a single flush at release covers.

That premise names two failure classes and misses a third: **the process going
away mid-utterance.** Against that one, a flush at release protects nothing,
because release never happens.

## What did NOT cause it

The log is misleading here and the next session to read it will reach for the
wrong culprit. In the same seconds as three of the six there is:

```
state: REFUSED listening -> idle  (grid from announceNext(only:):1471)
```

That is **`PanelState.allowsAmbientSurface` working exactly as designed** — an
arrival correctly refused the stage while capture owned it, so the panel stayed
in `listening`. `announceNext` does not stop the recorder; it reaches
`showIdleGrid` on its `.held` and `.nothingWaiting` paths and the transition is
rejected. The gate held. Only the in-memory buffer was lost.

The "already true — do not rebuild it" note in
`docs/rulings/ruling-an-arrival-does-not-move-the-panel.md` is therefore correct and
this measurement does not disturb it.

## The change

`LiveAudioCapture` (TranquilityCore) writes the WAV as the audio arrives:

- the header is written at open, so a capture that dies before its first frame
  leaves a valid empty file rather than a zero-byte one;
- the RIFF and data length fields are rewritten after every append, so the file
  is a *valid* WAV at all times, not merely a salvageable one — two four-byte
  fields per chunk is the whole cost;
- the file carries a `.wav.live` extension while open, so the boot sweep can
  tell an interrupted recording from a complete one. `finish()` promotes it,
  `abandon()` removes it, and a process that dies leaves it behind on purpose;
- `LiveAudioCapture.interrupted(in:)` finds what a previous process left open;
  `adopt(_:)` promotes it so it transcribes by the ordinary path.

Uncompressed WAV was already chosen for exactly this property — `AudioStore`'s
header says a truncated WAV is parseable to the last flushed frame where a
truncated compressed container is not, because its index lives at the end. The
format was picked so a partial file would survive. Until now nothing wrote one.

`Tests/TranquilityCoreTests/LiveAudioCaptureTests.swift` covers it, including
the 08 Aug scenario itself: append twelve seconds, never call `finish()`, then
assert the audio is discoverable, adoptable, and readable by `AVAudioFile`.

## Not done here

Wiring `Recorder` to it (app layer, one session at a time) and deciding what the
app offers the user on finding an interrupted recording at boot. Adoption is
deliberately not automatic: a boot sweep silently resurrecting audio the user
has forgotten saying is its own bug.

Also unbuilt, and worth more than the audio: **the streaming partial is never
persisted either.** `AssemblyAIStreamingSession` already accumulates finalized
turns plus in-flight partials and already models `endedWithoutFinal(partial:)`,
but `onPartial` feeds the HUD caption and nothing else — grep `QueueStore`,
`AudioStore` and `CaptureMarker` for `partial` and the only hit is an unrelated
temp-file extension. Persisting the running text would have returned the words
themselves on 08 Aug, not merely the audio.
