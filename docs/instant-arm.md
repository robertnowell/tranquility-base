# Instant arm (ruled: Wispr-pattern trust, adapted for an overloaded chord)

One commit. Revert with:

    git revert <this commit>

nothing else touches this surface; the revert restores a56763a's behavior
exactly (152 tests, latency instrumentation still in place).

## The problem this solves

The reply chord is overloaded: bare ⌥ is a tap (hands-free lock/send), a hold
(push-to-talk), and the first key of every ⌥-chord special character while
typing. Because recording only began once the hold outlived the ~350ms
tap-vs-hold threshold, the mic actually opened **~520–535ms after key-down**
(measured at a56763a: threshold 350ms + 170–185ms teardown-and-engine-start),
clipping the first syllable of anyone who talks the moment they press.

## The design

On bare-⌥ key-down, after an **80ms grace period** (`HotkeyMonitor.armGrace`
— the grace exists because ⌥-chord typing lands both keys within a few tens
of ms, so typing NEVER flashes the panel):

1. **Visual** — the panel shows the arming face: the listening pill's
   geometry in the grayed/faint treatment (faint dot, flat meter, identity
   only if already in hand — the active conversation's label; nothing is
   probed). This is a REAL `PanelState` case, `.arming`, with its own
   legality rows and its own `render()` arm — not a hack around the funnel.
2. **Audio** — the Recorder starts capturing optimistically at the same
   moment, via `recorder.start(openingStream: false)`. The
   `StreamedUtterance` is NOT created at arm — no network session for audio
   a tap will discard. It is created at hold-resolution exactly as before,
   through `Recorder.openStream()`, which feeds the stream everything
   buffered since the arm under the tap's own lock (ordering-safe), and the
   stream's pre-open buffer (the buffer-then-flush design documented in
   AssemblyAIStreaming.swift) carries it across the socket handshake.
3. **Resolution**:
   - Held ≥ threshold → `.replyBegan` as today. The arming face upgrades to
     the live listening pill (`.arming` admits exactly one successor,
     `.listening`); the stream opens and the backlog feeds in. The latency
     log now also reports key-down→arming-visible and the buffered-ms at
     upgrade (the zero-loss accounting).
   - Released before threshold (a tap) → `.armAborted` fires BEFORE the tap
     meaning, the optimistic capture is stopped and DISCARDED — no utterance
     row, no file write, no transcription, one log line
     (`arm: discarded, Nms audio`) — and the panel reverts to EXACTLY the
     face it was showing before arming (`StatusHUD.revertArming` restores
     the stashed state + face whole; from hidden, arming surfaces the panel
     and the revert re-hides it). The tap's existing meaning then executes
     untouched.
   - Another key / a click / a second modifier while ⌥ is down →
     disqualified as today; if the grace hadn't elapsed nothing ever showed;
     if it had, the abort fires AT the disqualifying event (not at key-up —
     the typist may keep ⌥ down for several characters).

### Where the decisions live

`ReplyGestureMachine` (VoiceDispatchCore) is the extracted, pure arm/hold
timeline: the monitor schedules the timers and feeds CGEvents in; every
decision about what they MEAN — arm, abort, begin, end — is the machine's,
and is unit-tested with synthetic timelines (E1). `HotkeyMonitor`'s existing
constants (0.35s threshold, the sawOtherInput guard, the formUnion chord
disqualification, the tap classification switch) are intact; the machine's
effects for a release run before the tap switch, so `armAborted` always
precedes `optionTapped` from the same key-up.

### Legality rows (`PanelState.arming`)

- Enterable from: hidden, idle, preparing, speaking, result, receipt,
  settings (the states that admit everything). The capture states —
  listening, transcribing, pendingSend — refuse the FACE (their stage-
  ownership rows are unchanged); the audio still arms there when the
  recorder is free (e.g. re-record during transcription), so the
  first-syllable fix applies to those paths too, just without pixels.
- `.arming` admits only `.listening` (the upgrade). Ambient repaints are
  refused by the table; the abort restores the stashed prior state through
  the restore door; an explicit dismiss tears down through `endCapture`
  (`.arming` owns the stage — the mic is open).
- `isCapturingAudio` is true for `.arming`: the ⌃⌥-announce guard, the
  depth-1 guard, and the hail guard all already refuse over an open mic.

## Accepted trades (documented, ruled)

- **The orange mic indicator now lights at arm** — ~80ms after any bare-⌥
  press that survives the grace, including taps (a tap's capture is
  discarded ~100–300ms later and the indicator goes dark again). This is the
  Wispr trust pattern: the indicator says "capturing", and capturing
  optimistically is the feature.
- **Playback bleed in the arm window**: `speech.stop()` still happens at
  hold-resolution (a tap must not silence playback), so an armed capture
  during an announcement buffers ~270ms of the app's own voice before the
  stop. The transcript providers have always tolerated the few-ms bleed at
  mic-open; this widens that window slightly. The durable file is unchanged
  in kind.
- **A slow ⌃⌥ or slow ⌥-chord (second key later than 80ms) briefly shows the
  arming face** before the immediate abort restores the prior face. The
  grace covers normal typing cadence; the flash is the cost of the trust
  pattern on an overloaded chord.
- Ruling 14 interaction: the arm window deliberately does NOT cancel the
  return-to-grid clock (arming is speculation, not attention); if the
  clock's work item fires into the arm window it consumes itself, so the
  abort path restarts the clock when its revert lands on a dwelling card.

## Safety evals (all PASS; this shipped only because they did)

**E1 — typing-chord immunity** (unit, `InstantArmTests`): synthetic
timelines against `ReplyGestureMachine` — ⌥-down +40ms keyDown → no arm
event ever, even when the grace/hold timers still fire; ⌥-down +200ms
release → arm fired then abort; chord growth after arm → immediate abort and
the later hold fire is dead; disqualification mid-reply → abortReply at
release; non-reply chords → nothing; machine resets between gestures; timer
firings after release are inert. 10 tests. **PASS.**

**E2 — discard completeness** (live, `--selftest-arm`, 2026-08-06T05:44Z):
arm→tap-abort driven through the real handler with the real recorder and
store; asserted at the store level: utterance rows 179→179, audio files
1822→1822, stream sessions asked for: 0 (nil-returning counting factory).
One log line per discard (`arm: discarded, 41ms audio`). **PASS.**

**E3 — revert correctness** (live, `--selftest-hud`, same run): arming
driven from each prior face — grid, speaking, hidden — with the full widget
matrix (15 widgets + state + visibility) compared before/after abort:
`restored=true` for all three. Grid and speaking restore the exact matrix;
hidden restores its observable contract — state `hidden`, panel off-screen —
because `render()` short-circuits before the widget baseline while hidden
(the panel may not even be built), so the widget values under hidden are
unobservable residue by design, rebaselined before the next surface. From
hidden the arm surfaces the panel (`visible=true` while arming) and the
revert re-hides. Upgrade leg: `.arming` → `.listening` admitted, meter live.
`--pose arming` added. **PASS.**

**E4 — no mic wedge** (live, `--selftest-arm`): both abort paths — tap-abort
(`recorder.abandon()`, the same exception-firewalled teardown as every
capture stop) and upgrade-then-`replyAborted` — end with
`recorder.isRecording == false`. **PASS.**

**E5 — latency proof** (live + review): measured grace-fire→render 4.7ms
direct (budget 30ms); the handler's own live lines during the same run:
`key-down→arming-visible` 4–15ms past the 80ms grace. Review-level
assertion: in the `armWindowOpened` handler the render precedes
`recorder.start()`, and between the grace timer firing and `render()` sit
only in-memory stash writes — no subprocess probe (identity comes from
`activeConversation`, never `resolveReplyContext`), no engine work, no
store reads. **PASS.**

One measured honesty note: the AVAudioEngine's FIRST start after launch is
cold (~730ms observed; ~66ms warm). That cost exists today too — it was
simply paid after hold-resolution. Instant-arm moves it ~270ms earlier;
audio flows from engine-live either way, so the "zero-loss window" claim is
about the buffer covering everything from engine start, which E6 proves.

**E6 — first-syllable fix proof** (unit, `InstantArmTests`): byte-accounting
— an arm-window backlog fed before the stream opens arrives at the socket
first, complete and in order, followed by live chunks (pre-open buffer
verified under the arm pattern); and every captured byte reaches the durable
file (`captureAndTranscribe` size accounting). At upgrade the live log
reports `Nms already buffered, zero-loss window` — the buffer begins at
engine start (arm), so the threshold window is fully covered. **PASS.**

Full suite: **165 tests** (152 at a56763a + 13 new), 0 failures.
Selftest log evidence: app.log lines `selftest arm[...]` and
`selftest-arm ...` from the clean-worktree build of this commit.
