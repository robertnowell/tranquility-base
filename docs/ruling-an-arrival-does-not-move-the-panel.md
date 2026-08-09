# An arrival does not move the panel, and does not talk over a live microphone

Ruled 08 Aug 2026, spoken, in the same conversation as
docs/ruling-the-collapsed-strip.md. Two rulings about the same moment — a turn
comes back — and both are behaviour changes, not descriptions of what ships
today. Written down per CLAUDE.md rule 4. Not built.

## Ruling 1 — the arrival changes nothing about the panel's shape

> "Basically, whatever the current state is, it shouldn't change [when] an agent
> comes back. If the UI is completely minimized… "

The panel's visibility and its width are **user state**. An arrival may change
what the panel *says* — a lamp goes green, the count moves — and may never
change how big it is or whether it is on screen. Dismissed stays dismissed.
Collapsed stays collapsed. Expanded stays expanded.

This is the collapsed-strip ruling's stickiness rule extended one step: it is
not only that the app must not collapse the panel for you, it is that the app
must not *open* it for you either. The two halves are the same principle and
should be read together — the user owns the width, and the user owns the
visibility.

### What ships today, and why this is a change

`surfaceArrival` (main.swift) ends in `hud.showIdle(rows:)`, which raises the
panel. `PanelState.allowsAmbientSurface` returns true for **`.hidden`** as well
as `.idle` (PanelState.swift:106), so a dismissed panel is re-raised by the next
arriving turn that clears the gate. That is the behaviour this ruling reverses.

The tick's *second* paint already has the right shape and says so in a comment —
"Never raises the panel: visible-and-idle only" — it repaints lamps only when
`hud.isOnScreen`. Ruling 1 is, roughly, that the arrival path should adopt the
same discipline the refresh path already has: **paint the truth, never change
the frame.**

Note that this makes the menu-bar annunciator load-bearing rather than
decorative. It is already refreshed every tick and cannot go stale (WS-B,
`menuBarCount`), which is what makes "dismissed stays dismissed" safe: the count
is still visible, and nothing was lost by not raising a window.

## Ruling 2 — say the callsign, but check the microphone first

> "It shouldn't even say the callsign out loud… well, actually, maybe it should,
> I don't know. I guess it should. I would say do a quick mic check before
> announcing a callsign. For example, if the mic is busy — especially if we're
> currently listening to the user, we should not talk."
>
> "If someone's currently speaking, you know, they're on a Zoom call or
> something, we shouldn't speak. So if we can check if the mic is active…
> honestly, we want to check the ambient noise level. If they're in a
> conversation with somebody, or if they're just talking out loud, we shouldn't
> interrupt them."
>
> "On the flip side, if the room is just loud, then it doesn't hurt to speak.
> But if the grid is shown, or the strip is shown, and the room is loud, at least
> they'll see the lamp go green. So that's probably good enough — and the risk of
> interrupting someone is great enough that we don't want to do that."

**The hail survives.** A2's spoken callsign is still the right behaviour, and
this ruling does not cut it — it is the away-channel doing its one unprompted
job. It gains a precondition.

**The precondition: a live microphone is a veto.** If the input device is in use
— by us or by anyone else — the hail is held, exactly like every other
`InterruptGate` veto: held, not dropped, and the lamp is still green when the
panel is next looked at.

**Silence wins ties.** The ruling reasons its way to a loud-room exception and
then declines it: the visual channel already carries the news, so there is no
case worth the risk of talking over a human being. A session tempted to add a
"but it's only background noise" carve-out should read the last quoted sentence
again — that carve-out was considered and refused at the moment the ruling was
made.

### Already true — do not rebuild it

"Especially if we're currently listening to the user" is **already law**, via
state rather than audio: `allowsAmbientSurface` is false for `.arming`,
`.listening`, `.transcribing`, and `.pendingSend`, so nothing ambient — panel or
voice — can fire while our own capture owns the stage. No new signal is needed
for the app's own microphone use. The gap is *other applications'* use.

### The hole this closes

`InterruptGate.mutedApps` (zoom.us, Google Meet, Teams, FaceTime, Keynote) is
matched against **`frontmostApplication()` only**. A Zoom call while you read
your terminal — the overwhelmingly common shape of the failure — has Zoom in the
background, matches nothing, and the app speaks over you. The list is also
inherently incomplete: it can only ever name calls someone thought of.

A device-in-use signal subsumes the whole list and needs no maintenance: it
catches Zoom in the background, every conferencing app nobody added, screen
recorders, and system dictation.

### How, concretely

`kAudioDevicePropertyDeviceIsRunningSomewhere` on the resolved input device.
Reasons this is the right instrument:

- `AudioInputDevice.swift` already carries the identical
  `AudioObjectGetPropertyData` pattern for transport type and channel count. The
  addition is a property read of a `UInt32`, in the file that already owns every
  other fact about the input device.
- It requires **no new permission** and **does not open the microphone** — it
  asks CoreAudio a question about the device, so it does not light the recording
  indicator and does not appear in Control Center.
- It becomes a fourth `InterruptGate.Signals` closure, which means it is
  injectable and the drills can assert both sides without a real Zoom call. The
  Signals struct exists precisely because live-state reads once made fifteen
  tests depend on what was in front on the developer's screen.

## Ruling 3 — the courtesy check: listen for a moment before speaking

Ruled 08 Aug, later the same evening, **overriding this session's earlier
recommendation against ambient sensing**. The recommendation argued against a
permanently open microphone; what is ruled is not that.

> "You could just open the mic for 5 seconds if it's not in use. Can you check
> if it's in use? If it's in use, that's a signal. But if the mic is not in use,
> you can put it in use and just do a noise check. You're not even transcribing
> anything, you're just checking if people are talking."
>
> "It's just to check if you're about to interrupt them. If there's people
> talking around, you should not speak. It's that simple. It's a courtesy thing.
> It's just listening before you talk."
>
> "From a privacy perspective, we're not trying to spy on you. We just don't want
> to interrupt you."
>
> "As long as we don't have — like, we're unable to turn on the mic for just a
> quick second to listen before we're about to talk, and that's the only time we
> do it — that's fine."

**The bound is the ruling.** The microphone opens *only* in the moment before an
unprompted announcement, for a few seconds, and never otherwise. That is a
different object from an always-on sensor, and the earlier objection does not
reach it: an indicator that lights for five seconds immediately before the app
speaks is not a surveillance story, it is the app visibly doing the thing it
just told you it does.

### The ladder, in order

1. **Is the device in use by anyone?** `kAudioDevicePropertyDeviceIsRunningSomewhere`
   — instant, no permission, does not open the mic. In use → **hold**. This alone
   catches every app-mediated case (background Zoom, Meet, Teams, recorders,
   dictation) and is the reason the check below is rare.
2. **Otherwise, open the mic for a few seconds and listen.** Speech-like energy →
   **hold**. Quiet → speak.

### The native recogniser is already here, already on-device, already permissioned

Asked 08 Aug: "can't we run native speech-to-text, which isn't a network call…
that's our fallback, right? I guess it's enable transcription, that's a user
permission on a machine that has to be enabled."

Yes, and it costs nothing new. Verified in the tree:

- `AppleSpeechRecovery` (Transcription.swift) is the **last provider in
  `RecoveryChain`** — "cloud first for quality, on-device last because it can
  never be unavailable." `SFSpeechRecognizer` is already a dependency.
- `NSSpeechRecognitionUsageDescription` is **already in the Info.plist**
  (scripts/bundle.sh:70). No new permission, no new prompt, no fourth item in
  onboarding. The "three permissions reasoned better than four" fight
  (`bd9e71a` / `d0cf0ac`) does not get reopened by this.
- `requiresOnDeviceRecognition = true` is **already set** (Transcription.swift:143).
  The on-device discipline is established practice here, not a new claim.

**One inversion is mandatory.** Today the line reads
`if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }`
— so on a machine lacking the on-device model, dictation silently uses the
network. For dictation that is an accepted quality trade the user opted into by
speaking. For the courtesy check it would mean **shipping ambient room audio to
Apple to decide whether to say a callsign**, which inverts the entire point.

So: if `supportsOnDeviceRecognition` is false, the courtesy check does not run
the recogniser at all. It falls back to level-only, or holds. It must never
reach the network. This is the one place the existing pattern must not be
copied verbatim.

### Words as a signal, never as content

The check asks the recogniser one question — **did any word come back?** — and
never looks at which. That is precisely the discrimination the ruling asked for
("catch if we can get any words, or if it's just loud"): a human talking
produces words, a fan and a passing truck do not.

Pairs cleanly with the RMS floor already in `Recorder`: loud with no words is
noise and speaking is fine; any word at all holds the hail.

A podcast or a video produces words too, and will hold the hail. That is the
right degradation — talking over something you are listening to is the same
discourtesy — and it needs no special case.

**The purist alternative, if "no text is ever produced" matters more than
speed:** `SoundAnalysis`'s built-in classifier (`SNClassifySoundRequest`) scores
audio against sound classes including speech, on-device, and never produces text
at all — so it needs only the microphone permission, not the speech one. Better
privacy property, one more framework, and a confidence threshold to tune instead
of a word count. Recommended if the check ever moves somewhere the speech
permission is not already granted. Not recommended today, because the recogniser
is already wired and the word-count signal is trivially easy to threshold.

### Never keep the words — and the privacy question dissolves

The ruling wonders aloud about transcribing a couple of words and then worries
about it ("maybe you don't want to do that for privacy reasons… obfuscate them
or something, like '4 words detected'"). The worry is well-placed and the
mitigation is unnecessary, because **the content is not needed**: knowing that
someone is speaking does not require knowing what they said. The recogniser
runs, the callback reports that words arrived, the count is the whole signal,
and the strings are never read, logged, or stored.

Note this is a sharper rule than the app applies to dictation, deliberately.
`Transcription.trace` logs your words on purpose, and README says so — that is
content you asked the app to capture. Room audio captured to decide whether to
speak is not, and does not get the same treatment.

So the rule is stronger and simpler than obfuscation. There is no transcript to
obfuscate, because none is ever produced. No audio is buffered past the check,
nothing touches the network, and the only thing that outlives it is a boolean and
a level number in `GateObservationLog`. "We store an obfuscated transcript" is a
promise a user has to trust; "there is no transcript" is a property they can
verify.

### The primitive already exists

`Recorder` was built for this shape without knowing it:

- `start(openingStream: false)` opens the mic **with no network session** — its
  own comment says "no network session for audio that a tap will discard."
- The tap already computes per-buffer RMS into `peakLevel` / `level`. Ambient
  level needs no new DSP to begin with.
- `abandon()` is the discard path: it clears the buffer
  (`removeAll(keepingCapacity: false)`), removes the tap, and stops the engine
  **without returning `Data`**. `stop()` returns audio; the courtesy check must
  never call it. That one substitution is what makes "nothing is kept" a
  structural property rather than a policy.

### Bias the detector — the errors are not symmetric

A false positive (we think someone is talking, we stay quiet) costs nothing: the
hail is held, the lamp is still green, the next tick tries again. A false
negative (we think the room is quiet, we talk over a sentence) is the entire
failure this ruling exists to prevent.

So the threshold leans toward silence, and a crude detector is adequate — which
is fortunate, because separating "person talking" from "podcast" from "loud
fan" reliably is genuinely hard. **Any speech-like energy at all holds the
hail.** Nobody should build a classifier here.

### Ship it log-only first

`GateObservationLog` exists for exactly this and says so: "the plan calls for
running log-only for a day before the gate is allowed to suppress anything,
because thresholds tuned in the abstract are usually wrong." An ambient-level
threshold is the most abstract-tuned number anyone will pick in this codebase.
Run the check, log what it would have decided, suppress nothing, then choose the
number from a day of real rooms.

### Open, and small

- **The hail is delayed by the length of the check.** Probably fine — it is an
  ambient announcement, not a response to a keypress — but it is a real latency
  change and should be a named constant, not a literal.
- **The indicator lights unprompted.** For a few seconds, with no user action
  preceding it. Honest, and still the one moment a user might ask why. Worth
  deciding whether the panel says anything while it happens (this session's read:
  no — a "checking if you're busy" placard is more interruption than the hail).
- **A capture that starts mid-check wins.** If the user holds ⌥ while a courtesy
  check is running, the check aborts immediately and the capture takes the
  device. The check must never be able to make the app feel like the mic is
  stuck.

### Why not "let the collapsed strip appear, at least"

Considered and declined on 08 Aug, by the ruling's own reasoning, which is worth
preserving because it is the tempting mistake:

> "I could be tempted into the argument that the collapsed panel at least should
> appear when an agent comes back. But now we violated two things — if it's
> minimized and a collapsed panel appears, I have to bring it back to full width.
> Whereas if I just hit ⌃⌥, it brings the grid back exactly where I want it."

The defect is that **an auto-appearing panel has to pick a width, and any width
it picks is a guess against a stored answer.** If it appears collapsed, a user
whose stored state was expanded now has to expand it — the app has both un-hidden
something they hid and overwritten a preference they set. `⌃⌥` has neither
problem: it restores the stored width, because the user asked.

This is the same principle as the collapsed strip's stickiness rule, and the
reason ruling 1 is not a matter of taste: any behaviour where an arrival sets the
panel's shape is a behaviour where the app overrules a preference it was given.

### The residual soft spot

Rulings 1 and 3 together describe the one configuration where **the voice is the
sole channel** — fully dismissed, no lamp on screen, only the menu-bar count that
nobody is looking at. The "silence wins ties" argument leans on the visual
fallback existing, and there it does not.

So the veto does the most work in exactly the state where being wrong costs the
most, which is an argument for the courtesy check being *stricter* when
dismissed than when a strip is visible — not an argument against ruling 1.
Recorded, not ruled; and cheap to revisit once the log-only pass has real
numbers, which is the right order anyway.
