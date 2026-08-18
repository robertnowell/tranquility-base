# The panel answers the pointer

Ruled 18 Aug 2026, in a voice session, against the implemented build: "as
implemented." Written after the operator asked for one thing and one question:

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

2. **The ink says the pointer is on *this* one.** One step brighter —
   `StateLegend.hovered`, a fixed **+8 ΔL\***, applied by scaling the colour's
   channels rather than by blending it toward anything. Scaling preserves
   saturation exactly, so a caution hovers to a brighter caution.

3. **Nothing moves.** No lozenge appears, no weight changes, nothing grows,
   nothing shifts. A panel where things jump under the pointer is an interface
   asking to be looked at, and this one exists not to be. It is also the same
   rule the collapsed strip already enforces on itself ("a revealed row would
   push the grid up and resize the panel on a mouse-over").

4. **No control rests at `ink`.** The brightest ink belongs to the prose, and a
   control resting there is louder than the message it sits under. `secondary`
   is the ceiling for a control at rest: 6.69:1 against the surface, legible
   with room to spare, and one clean step below the message.

   This rule was originally justified twice over — hierarchy, *and* "`ink` has
   no step left to take". The second half is no longer true (see the
   measurement below) and the rule stands on the first, which was always the
   real one. The card's TITLE does rest at `ink` and that is correct: it is
   content that happens to be a door, not a control, and it now answers the
   pointer like everything else.

A row-shaped control keeps the wash it already had (`Palette.hover`) instead of
the ink step. Rule 1 applies to it all the same — the wash says *which* row, and
only the cursor says a row is a control rather than a lit read-state.

### The step function, and how it was chosen

Three implementations of "one step brighter" shipped into this file inside one
afternoon, two of them within half an hour of each other, written by sessions
that could not see each other's work. Rule 4 of CLAUDE.md asks a reversal to
cite a measurement, so here is the one that picked the survivor:

| resting ink | discrete ramp | 35% toward `ink` | scale to +8 ΔL\* |
|---|---|---|---|
| `hint` | ΔL\* 4.6 | ΔL\* 7.2 | ΔL\* 8.3 |
| `secondary` — where most controls rest | ΔL\* 7.7 | ΔL\* 2.6 | ΔL\* 8.4 |
| `accent` — the doors | ΔL\* 10.9 | ΔL\* 10.2 | ΔL\* 8.4 |
| `ink` — the card's title | **no step** | ΔL\* 0.0 | ΔL\* 8.2 |
| `fault` — the amber pill | **no step** | ΔL\* 2.9 | ΔL\* 8.3 |
| `ready` — the go-green | **no step** | ΔL\* 2.9 | ΔL\* 8.0 |

A **ramp of named tiers** gives good steps and answers only the five colours on
it. Three real controls sat still under the cursor: the amber pill that the
attributed-string helper was written to protect, the go-green, and the card's
title — which is exactly what the operator reported ("it does show the cursor
pointer, but it doesn't have the change text colour impact").

A **blend toward `ink`** answers everywhere and says almost nothing where it
matters, because the step shrinks as the colour approaches the target. This
codebase already knows the price of that: the lamps carry a ΔL\* 6.0 floor
because 4.2 measured *invisible* at 9px while ΔE2000 called it twelve times over
threshold.

A **scale to a fixed ΔL\*** is the one that holds. It is defined for every
colour, it is the same perceptual distance everywhere, and — because multiplying
channels is not the same move as mixing in a grey — saturation comes through
untouched: amber 0.67 → 0.67, green 0.42 → 0.42, measured.

The floors ride the launch drill: `hovered(accent)`, `hovered(secondary)` and
`hovered(ink)` are in `contrastFloors` as computed values rather than minted
tokens, so a change to the step function that dims a control fails the gate.

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
- `StateLegend.hovered` — one step function for the whole panel, and
  `StateLegend.hoveredInk` for the targets that carry attributed text (the
  title, the state pill, the placard words) rather than a tint.
- `quietAction` rests at `chrome` (secondary) instead of `ink` — rule 4, and the
  only *resting* appearance this pass changes.
- Cursor rects on the grid rows, the list rows, the placard halves, the
  checkbox, and the collapsed strip.
- `hoverDrill` and `chrome` in the launch self-tests assert the standard rather
  than the call sites: every control steps, every step clears the text floor, no
  control rests at `ink`, every ink lifts by the same ΔL\* ±1 (including the
  three the ramp could not answer), and `fault` and `ready` keep their
  saturation. `titleAnswersTheCursor` is asserted separately from
  `pillAnswersTheCursor`, because they fail separately — the pill rests
  mid-ramp and passed the whole time the title was silent.

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
