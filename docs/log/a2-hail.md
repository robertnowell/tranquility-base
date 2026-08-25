# A2 — the hail: a chime and a name, then standby

Baseline dadd4ab (the grid). App-layer only; Core untouched — the dormant half
(`Announcement.hailText`, 09cb796) stays dormant, see "the fetch" below.
Binding inputs: the ruled design (unchanged all day), docs/log/wiring-a4.md's A2
note ("a flow change, not a call site"), docs/log/ws-b-grid.md.

## What changed

Ambient arrival used to surface the panel silently and stop there. It now
hails: after the existing gate and frontmost-tab checks and after the panel
surface, `surfaceArrival` calls `speakHail(for:)` — a quiet chime (Tink at
half volume, 300ms of air after it) followed by JUST the callsign, spoken
through the normal speech chain. Nothing else is said. The summary plays only
when the user presses ⌃⌥ ("go ahead"), exactly as before this change.

Silence after a hail is **standby**: the grid row stays lit, no cursor moves,
nothing is lost, and the same turn never hails twice. ⌃⇧ disregards as today.
No toggle — the ruled design shipped as ruled.

## The no-interrupt rule

The voice is the away-channel, and the hail is its ONLY unprompted use. It
never interrupts, structurally:

- If anything is already audible or in flight (`isAnnouncing`,
  `speech.isSpeaking`, `speech.isPaused`, `recorder.isRecording`,
  `hud.isCapturingAudio`), the audio is **skipped** — the surfaced panel and
  the lit lamp ARE the hail. Logged as `hail: silent (audio busy)`. The turn
  is still marked hailed: skipping the audio is not a request to chime later.
- The spoken part takes the `announceTask` slot by **awaiting** the previous
  holder, never cancelling or `speech.stop()`ing it — the inverse of every
  other taker of that slot, because a hail must not interrupt anything, ever.
  Holding the slot means a ⌃⌥ press during a hail cancels the hail cleanly
  and plays the summary, exactly the serialization every utterance obeys.
- If the arriving session's tab is frontmost, no panel and no hail (existing
  check, unchanged): showing up is enough, and you are already there.

## One hail per arrival

`lastHailedTurn` ("sessionId:latestId") guards event identity. Intake ticks
call `surfaceArrival` only when rows were actually inserted (`turnArrived`),
so tick re-surfaces never hail; a superseding turn from the same session has
a new `latestId` and hails again — it is a new turn.

## The fetch

The hail target is `coordinator.nextToAnnounce()` — the same call the
frontmost check already made (now hoisted), the same turn ⌃⌥ will play, with
no cursor advanced and nothing marked heard. `Announcement.hailText` itself
cannot be obtained without the speak path (constructing an `Announcement`
app-side is not possible — internal memberwise init — and `prepared.take`
consumes the prepared summary), so the app computes the identical expression
from the same `WaitingSession` fields: `callsign ?? Callsign.directoryWord(cwd:)`.
The Core property stays the contract; the comment at the call site points at it.

No new dogfood kind: `announcementSpoken` means the summary was spoken, which
a hail deliberately is not, and nothing else fits. `Permissions.log("hail: …")`
records every hail (spoken or silent-busy) in app.log.

## The session's voice

Mid-pass, f6d3de0 (the Core session) ruled per-session durable voices: "the
ear binds a voice to a stream of work before a name lands." The hail is the
first sound a turn makes, so it is exactly where that ruling pays: the hail
speaks in the session's own voice — same roster derivation as the
Coordinator's announce path (`VoiceCatalog.cached()` ids, sorted, first 10;
`store.voiceId(for:roster:)`), nil falling back to the narrator. One noted
consequence: a session whose first-ever utterance is a hail gets its voice
assigned at hail time rather than first announce — same round-robin, same
durable fact, just a moment earlier in the same arrival.

## Verification

- `swift build` + `swift test`: green, 143 tests, 0 failures (142 baseline
  + f6d3de0's voice-durability test).
- `scripts/bundle.sh`, `pkill -f TranquilityApp`, relaunched from
  `.build/debug/Tranquility Base.app`.
- Live, in app.log, on a REAL arrival — the full ruled flow end to end:
  - `23:06:46 ambient: surfaced for 2 waiting`
  - `23:06:46 hail: memory directory for 3be88b72 turn 1219` (unminted
    session — directory-word fallback, as designed)
  - `23:06:47 state: idle -> preparing (announce requested)` — the user
    pressed ⌃⌥ ("go ahead") and the full summary played; the superseded hail
    utterance was cancelled cleanly (`chain: stopped before fallback;
    staying silent`) — no overlap, no double voice.
- The complementary rule, also observed live: a synthesized spool Stop event
  (sanctioned test path) landed at `23:10:58` (`menubar: count= 3`) while
  the user was mid-dictation — capture states refuse ambient surfacing, so
  no hail fired and none fired later: an arrival during a conversation shows
  up in the grid and the count, silently. That synthesized turn for
  promotions-29 (04cbee61) remains queued; its next real turn supersedes it.
