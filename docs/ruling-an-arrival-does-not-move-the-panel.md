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

### Ambient noise level — recommended against, and not ruled

The ruling asks for it and then removes its only purpose. Its job was to
separate "loud room, safe to speak" from "conversation, stay quiet"; the ruling
then decides the loud-room case does not need the exception. What is left does
not justify the cost:

- Measuring ambient level means **holding the microphone open continuously**. On
  macOS that lights the orange recording indicator permanently and puts this app
  in Control Center's "using your microphone" list all day. An app whose entire
  pitch is calm and trust cannot be the one that appears to listen constantly —
  that is the screenshot that ends it.
- It would be the app's first always-on sensor, in a product whose privacy story
  is currently "the mic opens when you hold a key."
- `DeviceIsRunningSomewhere` already covers every case mediated by an app. The
  only residue is talking to a person in the room with nothing running, which is
  also the case no cheap signal can see.

*This session's recommendation, not ruled: ship the device-in-use veto, do not
build ambient sensing.* If the residue turns out to matter, the honest next
step is a manual mute, not a permanent open microphone.

### One consequence worth deciding

Ruling 1 says a dismissed panel stays dismissed; ruling 2 keeps the spoken
callsign. Together they describe the only configuration where **the voice is the
sole channel** — no lamp is on screen to fall back to. The "silence wins ties"
argument leans on the lamp being visible, and when fully dismissed it is not;
only the menu-bar count is, and nobody is looking at it.

So the veto is doing the most work in exactly the state where being wrong costs
the most. Two defensible readings, and this session is not picking one:

- The veto is the same everywhere, and a held hail while dismissed simply waits
  for the next tick that clears it.
- Dismissed is a stronger signal than collapsed — the user put the panel away —
  and deserves a stricter gate, not an equal one.

Needs Robert.
