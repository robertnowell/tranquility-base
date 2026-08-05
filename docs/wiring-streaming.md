# Wiring the AssemblyAI streaming provider into the app's capture path

Everything lives in Core (`AssemblyAIStreaming.swift`); the app owns the mic,
so this is the whole App-side change — one object per utterance, three calls:

```swift
// key-down (alongside starting the existing recording buffer):
let stream = StreamedUtterance(
    provider: AssemblyAIStreaming(),
    lexicon: Lexicon.harvest(store: store).terms)   // keyterms fixed at open
Task { await stream.start() }

// in the existing input tap, next to where pcm16 is already accumulated:
if let chunk = BuddyPCM16Converter.pcm16Data(from: buffer) { stream.feed(pcm16: chunk) }

// key-up, where submitReply is called today:
let streamed = await stream.finish()                 // nil on ANY stream problem
let outcome = try await coordinator.submitReply(pcm16: fullPCM, streamed: streamed)
```

Notes, in invariant order:

- **The audio file is saved exactly as before.** `submitReply` →
  `captureAndTranscribe` writes the WAV and its row FIRST, whatever `streamed`
  is. Streaming can only remove the recovery-pass wait, never the recording.
- `feed` is safe before `start()` completes (chunks are buffered and flushed on
  open, order preserved) and after the stream has died (they are dropped — the
  file has everything).
- `finish()` returns a transcript only for a trustworthy explicit end-of-turn;
  start failure, missing key, mid-stream drop, truncation, or timeout (default
  3s) all return nil and the utterance recovers from the file as today.
- `BuddyPCM16Converter.pcm16Data(from:)` already resamples the capture format
  to 16 kHz mono PCM16 — the same data the durable buffer accumulates, so the
  tap needs no second conversion path.
- Provider tags distinguish the paths in `utterances`: `assemblyai-streaming`
  (streamed) vs `openai` / `apple-speech` (recovered from file).
- Verification without a mic: `vdctl transcribe-stream <wav>` replays any saved
  recording in `~/Library/Application Support/VoiceDispatch/audio/` through the
  live provider in pseudo-realtime.
