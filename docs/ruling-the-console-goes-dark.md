# Ruling: the console goes dark

**Ruled 09 Aug 2026.** Supersedes the light-console palette ruled 04 Aug
(vd-grid-mock variant A). The earlier ruling's own note said "a later work
stream may retune them; this one must not" — this is that work stream.

Per CLAUDE.md rule 4, a ruling that reverses an earlier one cites a
**measurement, not an argument**. The measurements are below.

---

## What started it

Two complaints, made independently and initially treated as separate:

1. The ready and working lamps could not be told apart.
2. The putty was low contrast — "especially in HTML it feels low contrast."

They turned out to be the same complaint.

## The lamps

Shipping pair: ready `#416B47`, working `#3E5A75`.

| | value |
|---|---|
| ΔE2000 | **29.0** |
| ΔL* | **4.2** |
| lamp-to-lamp contrast | 1.17:1 |

The perceptibility threshold for large adjacent colour patches is ~2.3 ΔE2000.
The shipping pair measured **twelve times** that and was still indistinguishable
at 9 px. ΔE is calibrated for large, adjacent, foveally-fixated patches; at 9 px
across separated rows it predicts nothing. **ΔL\* is the metric that tracks the
experience.** Every candidate in the experiments moved ΔE by less than 2 points
while ΔL\* nearly tripled, and only the ΔL\* changes were visible.

Supporting evidence: peripheral chromatic sensitivity falls faster with
eccentricity than luminance sensitivity (equal by ~20°), and small-field
tritanopia degrades hue perception at small angular subtense in both fovea and
periphery. 9 px at normal viewing distance subtends ~0.24°, below the ~0.5° where
discriminable colours begin to collapse.

## The contrast budget — why the surface, not the lamps, was the problem

On a light panel every element must be **darker** than the panel to be seen. So
the surface's lightness *is* the whole contrast budget, drawn on simultaneously
by four ink tiers, three lamps and the amber.

| Surface | L* | Usable range | Tokens failing their floor |
|---|---|---|---|
| Current putty `#C4C3B7` | 78.6 | 45 pts | 3 of 7 |
| Dimmed −9 | 69.4 | 37 pts | 6 of 7 |
| Mid −12.6 | 66.0 | 34 pts | **7 of 7** |
| Cockpit housing `#2A2C28` | 17.7 | **51 pts (above)** | — |

Two things follow. First, **dimming the putty for comfort cannot fix contrast** —
it shortens the budget every element draws on. Second, the shipping build was
already failing: `faint` at **2.13:1** against a 4.5:1 floor for small text, and
`fault` at **1.72:1** against 3:1 — the needs-you channel was the least visible
thing on the panel.

There is no light surface where the ink ramp and the lamps both fit. On the dark
ground the budget sits above the surface and is larger: **14.10:1 of room versus
the bright putty's 1.77:1.**

## Decisions

**The ground is dark.** `#2A2C28`. Reached independently twice — once from the
lamps (only surface with separation room) and once from the ink ramp (only
surface with legibility room).

**The lamp pair stays green + blue.** Green + purple measured *further* apart
(ΔE2000 36.7 vs 30.9) and was rejected anyway: purple does not read as
*becoming* green. Adjacent states in a process want adjacent hues — the palette
encodes the transition, not just the categories. The similarity that made the
pair hard to separate is the same property that makes it read as one process.
Separation is bought in lightness, which leaves the hue relationship intact.

**Working is the dimmest lamp.** ready 6.35:1, working 3.10:1. Ruled on the busy
panel: working is the state you are in most of the time, and seven equally bright
dots is a lit-up panel rather than a hierarchy. Note this move is only available
on a dark ground — where contrast runs one direction, dimming a lamp just makes
it harder to see; where it runs both, emphasis and calm become separable.

**Idle is an unlit socket**, 1.45:1. Dark-cockpit doctrine — the panel is dark
when all is nominal, a lit lamp always means deviation — falls out of the
arithmetic rather than being imposed on it. MIL-STD-411F §5.1.1.1 puts the same
rule numerically: an unlighted legend sits below 0.1 contrast, a lighted one
above 2.0.

**The card is dark too.** Tested against a light card and rejected: the grid and
the card are the same rectangle (`waitingRows.isHidden`, StatusHUD.swift:788/826),
so a light card is not the persistent two-ground pattern of an editor — it is the
same rectangle flipping ground ~134 times a day, with the return to the grid
being the slower adaptation direction. Card ink is `#C9C8BF`, **8.39:1**,
deliberately not the brightest available: at 11.15:1 it read as shouting, which
APCA (polarity-aware, unlike the WCAG ratio) scores at Lc −86.7 against the light
card's Lc 63.4 — 37% more perceptual contrast, spent only because the budget
allowed it.

**`faint` splits into `hint` and `faint`.** One token was being asked to be both
a legible hint line and a recessive decoration. `hint` owes the 4.5:1 text floor
and meets it at 4.57:1; `faint` is decorative only and owes nothing. This is the
actual cure for the mushy key line.

**`advisory` is renamed.** It becomes `working` (the lamp) and `accent` (the
GO TO AGENT affordance) — two distinct jobs that had been sharing one token named
for neither. NASA HIDH lists blue advisory as "not recommended for general use",
so the doctrinal name was not earning its keep either.

## Rejected

- **Green + purple** — discriminability is not the only axis; see above.
- **Dimming the putty** — spends the budget it was meant to fix.
- **Light card / dark grid split** — the two faces are one rectangle.
- **A per-face polarity rule** ("text-heavy light, symbol-heavy dark") — searched
  for and **not found** in NASA guidance, aviation human factors, or any major
  design system. The one real thing nearby is "dark cockpit philosophy", which is
  an alerting doctrine, not a theming rule. The polarity literature also
  contradicts the symbol half: the largest positive-polarity effect on record
  (η²=.30, d=2.17) comes from a pure symbol-discrimination task.

## Kept for the swap

The measured light half lives as a comment block in `Palette`. Not dead code —
it passes every floor a light ground can pass, with the ones it cannot called
out. Two traps noted there: the lamp step **inverts** between grounds (on light
the working lamp must be darker than ready to recede; on dark it is dimmer), so
the tables are not interchangeable row for row; and `socket` equals `hover` on
light because an unlit lamp against putty has to be carried by its ring — there
is no "off" that reads as off on a light ground.

## Found while landing

`CheckView`'s tick was a hardcoded `NSColor(srgbRed: 0.93, 0.93, 0.89)`. Correct
against the old dark green, **1.88:1** against the new brighter one — an invisible
checkmark, in one state, visible only at runtime. Now `Palette.surface`, 6.35:1.
This is the argument for the grep contract in `docs/palette-plan`: no colour
literal outside the palette.

## Not done here

- The contrast assertions belong in the launch self-tests (CLAUDE.md rule 7:
  `swift test` is not evidence about the panel). Every number above was computed
  by hand and will rot the first time someone nudges a hex.
- Idle vs exited sessions still share a treatment. Deferred by the user.
- Idle sessions should sort below active ones. Not a colour change.
- The card's second headline (`face.topic`) still ships; the title is not yet a
  second door to the session.

## Evidence

Research record: `~/Documents/deep-research/2026-08-09-annunciator-color-polarity/report.md`
(MIL-STD-411F and NASA HIDH full text; Buchner & Baumgartner 2007; Piepenbrock
et al. 2013; Dobres et al. 2017; Buchner, Mayr & Brandt 2009; WCAG 1.4.11; APCA).

Experiments: lamp separation, contrast budget, dark theme, card polarity, and the
face-swap test — five rendered pages, generated from the same colour maths used
to pick these values.

---

## Addendum, same day: the drill earned its keep immediately

The contrast floors are now asserted in the launch self-tests (`selftest
contrast:`), not just written down here. On its **first execution** the drill
failed — on the palette this document had already ruled.

`muted` measured 4.51:1 and `hint` measured 4.57:1. Both cleared their own
floors. The ramp was inverted anyway: the tier named "muted" was the more
legible of the two, so the visual hierarchy said the opposite of what the names
said. `muted` moved to `#A09F96` (5.30:1), restoring
ink 8.39 > secondary 6.69 > muted 5.30 > hint 4.57.

This is the case for asserting an ordering rather than a set of floors. Every
token passed its individual check and the hierarchy was still wrong, and no
amount of staring at the panel would have surfaced it — an inverted ramp renders
perfectly, it just quietly ranks things in the wrong order.

What the drill asserts: every token against its floor; lamp ΔL* ≥ 6; the ink ramp
strictly ordered; `hint` outranking `faint` (so the split cannot silently
re-merge); and the checkmark against `ready`, the one pair measured against
something other than the surface.

**Not yet run in the app.** The drill is wired into `selfTest()` and will execute
on the next `relaunch.sh`. Its arithmetic was verified out-of-process against the
hex values parsed from `StateLegend.swift` itself, because launching a second
instance to run it would have raced the live one for the global hotkey.
