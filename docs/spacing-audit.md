# The spacing audit: what the panel actually paints

First run 19 Aug 2026, over 19 faces, with `scripts/faces.sh` + `scripts/inkmap.py`.
Not a ruling — a measurement, and a recommendation that needs one.

## How this is measured, and why it had to be new

Every layout assertion in this repo measures **boxes**: a frame, a constraint
constant, a stack's spacing. The eye sees **ink**. Those are different numbers
here, deliberately and invisibly:

| control | painted glyph | layout box | invisible |
|---|---|---|---|
| gear | ~14pt | 26pt | 12pt |
| back chevron | ~9pt | 26pt | 17pt |
| `Controls` word | ~10pt cap | 20pt hover box | 10pt |

Every one of those paddings was ruled on purpose, for pointer targets. None of
them is wrong. But the panel aligns box-to-box, so **wherever one of these lands
first or last against an edge, its padding silently becomes margin.**

`scripts/inkmap.py` reads the pixels instead. It takes the PNGs
`scripts/faces.sh` already renders from the view hierarchy, finds every
horizontal band of paint, and reports the four painted margins per face — then
groups each margin by the value it takes across faces, because the finding is
never one number, it is two faces disagreeing about the same edge.

```
scripts/faces.sh /tmp/tb-faces
scripts/inkmap.py /tmp/tb-faces/berkeley
```

## What it found

The panel declares one contract, in one place:
`stack.edgeInsets = (top: 12, left: 14, bottom: 12, right: 14)`, `spacing = 6`.
Painted, across 19 faces:

| edge | values | verdict |
|---|---|---|
| **top** | 10.5 (16 faces), 11.5 (1), **15.0 (2)** | two outliers |
| **left** | 14.0 (17), 13.5 (2) | effectively one value |
| **right** | 14.0 (6), **17.5 (13)** | two populations |
| **bottom** | **0.0, 12.0, 12.5, 14.5, 19.5, 21.5, 23.5, 24.5** | seven values |

### Finding 1 — one cause, three edges

The 15.0 top, the 17.5 right and the bulk of the 21.5 bottom are **the same
bug seen on three different edges**: a hit-target box against a panel edge.

- **top 15.0** — settings and recent-audio open with the back chevron: a 9pt
  glyph in a 26pt box at a 12pt inset, so the first paint is 4.5pt low.
- **right 17.5** — 13 card faces end their top row with the gear: 3.5pt of
  box past the last lit pixel. The six faces at a clean 14.0 are the ones whose
  rightmost paint is a hairline or a plain label.
- **bottom 21.5** — 7 card faces end with the controls row, whose word carries a
  20pt hover box around ~10pt of ink: ~9pt of nothing, then the 12pt inset.

This is the finding worth acting on. It is not a per-screen problem and it is
not really a spacing problem — it is one principle missing.

### Finding 2 — the top inset is honest but uncalibrated

10.5 across 16 faces is *consistent*, and 1.5pt short of the declared 12. That
is type ascent: a label's frame starts above its cap height. Nothing is broken;
it means **12 in the code buys 10.5 on screen**, and the bottom inset (which
usually terminates in a descender or a box) does not lose the same 1.5. So the
card is top-lighter than its own constants claim.

### Finding 3 — the bottom edge is per-face by accident

Seven values. After Finding 1 is removed, what remains is that every face ends
with a different widget and each contributes its own internal padding:
the capture strip (24.5), the amber notice (23.5), the level meter (19.5), the
readback strip (14.5). Nobody chose those differences.

### Finding 4 — `settings` has no bottom margin at all

Painted bottom margin **0.0**. Content runs to the housing edge. This one is a
plain bug, not a pattern, and it is per-screen.

### Finding 5 — the row rules are not centred

Off the grid's bands: text sits **15.5pt below** the rule above it and **13pt
above** the rule below it. In recent-audio the same asymmetry runs the other
way. A rule that sits closer to one neighbour reads as belonging to it, which is
exactly what a separator must not do.

## The recommendation

**One principle, adopted centrally, closes Findings 1–3:**

> **Edges are measured to ink. A hit target is not a layout box.**

A control whose target is deliberately bigger than its mark grows that target
*outward* — through `hitTest` or a tracking area, which cost no layout — rather
than by inflating the box the stack aligns to. Then 12/14 in the code means
12/14 on screen, on every edge of every face, and the bottom stops being a
per-face accident.

Findings 4 and 5 are separate and small: one missing inset, one shared
row-with-rule component with symmetric padding.

**And the audit becomes a gate.** `inkmap.py` is deterministic and already runs
headless; the summary it prints is exactly the shape of a drill — one value per
edge is the pass condition, two is the failure. That is the honest way to keep
this fixed, and it measures the thing a person actually sees, which no assertion
in this repo does today.
