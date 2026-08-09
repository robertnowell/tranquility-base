# The acknowledgement light

Ruled 08 Aug 2026. Supersedes the single-pulse behaviour, not the 06 Aug ruling
behind it ("one press, one light") — that ruling is what this extends.

## What it says

A 3px bar along the top edge of the panel, in two colours:

| Colour | Token | Means |
|---|---|---|
| Blue | `Palette.advisory` | **Registered.** A key landed and was understood as input. The app has not done anything. |
| Green | `Palette.ready` | **Recognized.** That was a gesture and the app acted on it. |

The distinction is the point. A press that is received and a press that is
obeyed are different facts, and before this they looked identical — a press that
resolved into nothing got the same flash as one that ran a command.

## The lifecycle, and why it is a hold

**Colour up → hold 500ms → fade 250ms.** The hold is what makes this work.

The previous design pulsed opacity 1 → 0 over 500ms, starting to fade the instant
it appeared. Two consequences, both wrong:

1. **A two-tap gesture flashed twice.** ⌃ then ⌃ is one intention. It read as two
   separate flickers, which is exactly the stutter the 06 Aug ruling killed for
   holds and left alive for taps.
2. **A press could not change its mind.** By the time the second tap arrived
   there was no light still up to recolour, so a gesture resolving from
   "received" into "done" had nothing to show it with.

500ms is chosen against the hardware: ⌃⌃ and ⌥⌥ pairs run 50–100ms apart
(HotkeyMonitor's own measurement). The second tap of any pair therefore always
lands while the light is still up, and **recolours it** — blue → green, animated
over 180ms so the change itself is visible. One light resolving, never two flashes.

The fade is 250ms: slow enough not to snap, fast enough that the light never
reads as a status lamp. It is a receipt, not state.

## The mapping

| Gesture | Light |
|---|---|
| ⌥ tapped | green — a complete gesture on its own |
| ⌥ held (arm/capture) | green, **held** for the length of the press (06 Aug ruling, unchanged) |
| ⌃ tapped once | **blue** — the opening key of two chords; means nothing alone |
| ⌃⌃ | blue, then green when the second tap lands |
| ⌃⌥ | green — resolves as one gesture, on release |
| ⌃⇧ (dismiss) | green |
| ⇧ (pause) | green |
| deeplink | green — an instruction that arrived and is being carried out |

## What it must never do

**Light while typing.** Bare ⌥ opens every ⌥-chord special character and bare ⌃
opens every ⌃C. All classification happens on RELEASE, in
`HotkeyMonitor.endGesture`, behind the interference guard — a press that grew
into a real chord arrives as that chord's flags and an interfered press never
reaches the switch at all. A key-*down* signal would have lit the panel on every
⌃C, which is why `.controlRegistered` is emitted where it is and not earlier.

**Outrank a hold.** `acknowledge(_:)` returns early while `ackHeld` is set, so a
chord arriving mid-hold cannot cut the hold's own light short. Conversely a hold
beginning inside an acknowledgement's window cancels the pending stand-down and
claims the colour — otherwise a hold following a blue ⌃ would sit blue for the
whole press and say the wrong thing.

## Code

- `StatusHUD.Acknowledgement` — the two-case enum, colours from `Palette`.
- `StatusHUD.acknowledge(_:)` — colour, hold, fade. `ackStandDown` is the pending
  fade; cancelling it is what turns two presses into one light.
- `StatusHUD.holdAcknowledge()` / `releaseAcknowledge()` — the key-down/key-up
  span, unchanged in behaviour.
- `HotkeyMonitor.Transition.controlRegistered` — the only transition that carries
  no instruction. It exists so the light can report a press the app will not act on.
