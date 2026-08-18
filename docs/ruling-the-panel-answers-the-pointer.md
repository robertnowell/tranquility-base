# The panel answers the pointer

**STATUS: proposed 18 Aug 2026, awaiting a ruling.** The code implements it;
this line is what changes when it is ruled. Written after the operator asked
for one thing and one question:

> "A lot of our buttons and actual, like, hover states, lack any visual
> indicator that something is clickable… we should also look into, like, what
> should a hover state do? … at least we need probably some visual indicator,
> and a consistent visual indicator of a hover state, that doesn't impact
> readability."

## The measurement, not an argument

The panel was counted against its own inventory before anything was written,
on `origin/main` at 5ed326c:

| | count |
|---|---|
| distinct control kinds the pointer can act on | 25 |
| of those, carrying a pointing-hand cursor | 2 |
| of those, changing at all on hover | 5 |
| quiet text actions resting at `ink`, the prose's own colour | 5 |

The 25 are 14 `NSButton` construction sites, 8 `NSControl` subclasses (the grid
row, the list row, the placard halves, the voice and audio rows, the checkbox),
2 labels carrying click recognisers, and the collapsed strip.

The two that had a cursor are the card's title (`DoorLabel`, ruled 06 Aug: "the
cursor is the whole affordance") and the attachment chip's ✕. The five that lit
are row- or strip-shaped: the grid row, the list row, the placard half, the
check row, and the collapsed strip's content swap. Everything else — GO TO
AGENT, OPEN HUB, the gear, the collapse chevron, Don't send, the settings tabs, every ▶ and ⋯ in the panes — was
indistinguishable from a label at rest and stayed indistinguishable from a label
under the pointer.

That is not an oversight, it is the cost of a ruling the design is right to
keep. The card's actions are *quiet text*: "borderless, palette ink, no lozenge
— the button rows are dead". A quiet text action is the correct shape. It just
never grew the one thing that tells a quiet text action apart from the quiet
text above it.

## The standard

1. **The cursor says a thing is a control.** A pointing hand over the hit rect
   of everything the pointer can act on, with no exceptions — because on this
   panel a control and a label are the same object to the eye by design, and at
   rest nothing else distinguishes them.

2. **The ink says the pointer is on *this* one.** One step up the control's own
   ramp — `StateLegend.hovered`, walking `StateLegend.inkRamp`
   (faint → hint → muted → secondary → ink), with `accent` stepping to
   `accentHover` so a blue-grey control does not change hue to answer a mouse.

3. **Nothing moves.** No lozenge appears, no weight changes, nothing grows,
   nothing shifts. A panel where things jump under the pointer is an interface
   asking to be looked at, and this one exists not to be. It is also the same
   rule the collapsed strip already enforces on itself ("a revealed row would
   push the grid up and resize the panel on a mouse-over").

4. **No control rests at `ink`.** The brightest ink belongs to the prose. A
   control resting there is louder than the message it sits under *and* has no
   step left to take, so it cannot obey rule 2. `secondary` is the ceiling for a
   control at rest: 6.69:1 against the surface, legible with room to spare, and
   one clean step below the message.

A row-shaped control keeps the wash it already had (`Palette.hover`) instead of
the ink step. Rule 1 applies to it all the same — the wash says *which* row, and
only the cursor says a row is a control rather than a lit read-state.

### Three carve-outs

The settings tabs and a playing ▶ paint their own ink, because that ink already
carries a louder signal — which tab is open, which clip is playing. Hover does
not overwrite a louder signal with a quieter one. They take rule 1 and stop.

So does the voice pane's **Get**, for the opposite reason: it is the one control
on the panel with a box of its own, so it already looks like a button and its
title sits on its own fill rather than on the surface.

The onboarding window is out of scope entirely — its buttons are ordinary
bezelled AppKit controls in an ordinary window, and the platform's affordance is
intact there.

## Why readability cannot be spent here

Rule 2 is a step *up* a ramp whose every rung is a token that already clears its
own contrast floor, on a ground that only gets darker relative to the ink. Hover
therefore moves every control strictly towards legible and never away from it —
which is the whole reason the answer is ink and not a wash. A wash under an
accent action measures 2.96:1 and would put GO TO AGENT *under* its own 3:1
floor at exactly the moment somebody is reading it.

`accentHover` is measured at 4.94:1 (ΔL\* 10.9 above resting) and carries a 4.5
floor in `StateLegend.contrastFloors` — a hover value is read for as long as the
pointer sits on it, which is longer than a resting placard is read, so it owes
the text floor even where its resting value did not.

## On the pointing hand, since the house style says otherwise

macOS does not put a pointing hand on buttons; the web does, and Cursor does it
on everything. Claude Code's desktop app takes the middle position — hover
states, no pointer. This panel takes the pointer, and the reason is specific to
it rather than a preference:

- **A native button announces itself with a bezel. Ours cannot.** The lozenge is
  dead by ruling. The affordance the platform normally supplies through shape
  has to come from somewhere, and the cursor is the only channel left that costs
  no pixels.
- **This is a HUD, not a document.** There is no text to select on a card except
  the body, and the body is the one thing here that keeps an I-beam. Elsewhere
  on the panel an arrow cursor carries no information at all, so spending it is
  free.
- **The precedent is already ours.** The card's title has had the pointing hand
  since 06 Aug on exactly this argument, written down at the time: "a click
  target with no affordance is a secret". Twenty-three others kept the secret.

## What changed

- `ConsoleButton` (StatusHUD.swift) — cursor rect, tracking area, and the ink
  step, in one class, so rules 1 and 2 are properties of the type and not of
  each call site. Every panel button is one: go, open page, gear, collapse,
  back, past-back, the five quiet actions, the chip's ✕, the audio row's ▶ and
  ⋯, the voice row's ▶, the settings tabs, and the directory row's CHOOSE….
- `StateLegend.inkRamp` and `StateLegend.hovered` — "one step" as a position on
  a named ladder rather than a colour chosen per control, plus the new
  `Palette.accentHover`.
- `quietAction` rests at `chrome` (secondary) instead of `ink` — rule 4, and the
  only *resting* appearance this pass changes.
- Cursor rects on the grid rows, the list rows, the placard halves, the
  checkbox, and the collapsed strip.
- `hoverDrill` in the launch self-tests asserts the standard rather than the
  call sites: every control steps, every step clears the text floor, no control
  rests at `ink`, and the ramp climbs.

## What was considered and rejected

**A wash for everything.** One token, one indicator, already in the design. It
reverses the no-lozenge ruling by drawing a lozenge on hover, and it costs the
accent actions their contrast floor (2.96:1). Rejected on both counts.

**An underline on hover.** Cheap, and it does not touch colour. Rejected because
an underline means *link* in prose, and the card is prose — the one place on the
panel where the convention is already spoken for.

**Cursor only, no ink step.** The honest minimum, and it is what the title has
had for two weeks. Rejected because the pointer is a discovery affordance and
not a confirmation one: with three quiet actions 12pt apart in a row, the cursor
tells you that you are over *a* control, and nothing tells you which.
