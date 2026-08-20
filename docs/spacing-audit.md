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
| **bottom** | ~~0.0~~ · 12.0, 12.5, 14.5, 19.5, 21.5, 23.5, 24.5 | seven values (the 0.0 was a clipped capture — Finding 4) |

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

### Finding 4 — WITHDRAWN (20 Aug). It was the instrument, not the panel.

Originally written up as "`settings` has no bottom margin at all — content runs
to the housing edge, a plain bug". It is not. The pose was captured before the
panel finished growing to fit its content, with the LAUNCH row cut in half at
the frame edge. A face whose paint reaches its own bottom edge is not a face
with no margin; it is a face photographed too early.

Worth recording rather than quietly deleting, because this document's own method
section warns about exactly this transient — the animating frame that the drills
have been bitten by three times — and the audit walked into it anyway on its
first run. `inkmap.py` now flags any face whose bottom margin is under 6pt as
CLIPPED, excludes that face's bottom from the summary, and says why. The
instrument had to learn the lesson the drills already knew.

Nothing else in the audit is affected: `settings` was the only face near zero,
and the other seven bottom values all sit well clear of the edge.

### Finding 5 — the row rules are not centred

Off the grid's bands: text sits **15.5pt below** the rule above it and **13pt
above** the rule below it. In recent-audio the same asymmetry runs the other
way. A rule that sits closer to one neighbour reads as belonging to it, which is
exactly what a separator must not do.

## First fix, and the before/after (20 Aug)

Reported from the panel, not from this audit: *"the rows of agents' widths expand
beyond the top bar a little bit."* Correct, and it is Finding 1 wearing different
clothes — the same hit-target boxes, seen as INTERNAL misalignment rather than as
an outer margin. It is the most visible instance because the hairline directly
under the header spans the full column and acts as a ruler.

| grid face | left mark | right mark |
|---|---|---|
| the column (rules, rows) | 14.0 | 365.5 |
| header **before** | **21.0** (−7.0) | **362.0** (−3.5) |
| header **after** | 14.5 | 365.5 |

Fixed by pinning the two chrome buttons by their MARK instead of their box —
`StatusHUD.contentColumn` minus `ConsoleButton.inkOverhang`. The 26pt pointer
target is untouched; it now overhangs outward into the panel's own margin, where
nothing else is competing for the space.

`inkOverhang` had to go **two boxes deep**. A symbol button centres its image in
the 26pt target, and the image is itself padded around the glyph, so aligning by
`image.size` still left the chevron at 16.5 against a column at 14 — measured.
It rasterises the image once at build and finds the columns that actually carry
alpha.

Side effect across every face measured: the **right** edge collapsed from two
populations (14.0 and 17.5) to one — 14.0 everywhere. The gear was the only
thing holding the second value open.

Still open from Finding 1: the **vertical** half. `settings` and `recent-audio`
still paint their first mark at 15.0 against 10.5 elsewhere, because the back
chevron's box is taller than its glyph too. Same principle, different axis, not
yet applied.

## The card's floor: fixed, then REVERTED the same day — and it corrects this audit's thesis

The card's floor was pulled from 21.5pt of painted air to 12.5 on the strength of
the numbers in this document (#171). **It was a regression, and the numbers said
it was an improvement.** Reverted in full.

| | painted bottoms across eight faces |
|---|---|
| before | 12.5 · 14.5 · 19.5 · 21.5 · 23.5 · 24.5 |
| after the change | 12.5 (4 faces) · 14.5 · 19.5 · 24.5 |

By this document's own stated goal — *one value per edge* — the change was
progress: two more faces moved onto 12.5. Rendered and looked at side by side,
the two card faces were then visibly tighter than every other face, and on their
own they read cramped against the panel's rounded edge.

**Why the metric was wrong.** The eye does not compare painted margins. It
compares optical air, and that depends on what sits ABOVE the margin: 12.5pt
under the grid's hairline-and-wordmark looks settled, 12.5pt under a lone row of
small caps looks squeezed. The 21.5 this audit filed as "per-face by accident"
was doing real work — optical compensation for a light row against an edge — and
nothing in `inkmap.py` can see that.

**So the premise needs restating.** "One value per edge is the goal, two is a
finding" is the wrong goal. Uniform painted margins are not uniform-looking
margins. `inkmap.py` is a good detector of gross drift, and a good way to
attribute a difference once an eye has found one. It is not a design oracle and
must not be used as a target to optimise against.

**And the procedure was the real defect.** Every step of that change was measured
and none of it was looked at. A face renders to a PNG in one command — the pose
harness already exists — and eight of them stacked in one image showed the
problem in a second, after it shipped. For any change with a visual result:
render the faces, stack them, LOOK, and only then decide whether the change is
good. The measurement comes after, to say what moved and by how much.

## The recommendation

**One principle, adopted centrally, closes Findings 1–3:**

> **Edges are measured to ink. A hit target is not a layout box.**

A control whose target is deliberately bigger than its mark grows that target
*outward* — through `hitTest` or a tracking area, which cost no layout — rather
than by inflating the box the stack aligns to. Then 12/14 in the code means
12/14 on screen, on every edge of every face, and the bottom stops being a
per-face accident.

Finding 5 is separate and small: one shared row-with-rule component with
symmetric padding. Finding 4 was withdrawn — see above.

**And the audit becomes a gate.** `inkmap.py` is deterministic and already runs
headless; the summary it prints is exactly the shape of a drill — one value per
edge is the pass condition, two is the failure. That is the honest way to keep
this fixed, and it measures the thing a person actually sees, which no assertion
in this repo does today.
