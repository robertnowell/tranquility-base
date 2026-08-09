# The grid compresses to its lamps, and the user owns the width

Ruled 08 Aug 2026, spoken. This schedules the direction that
docs/ws-b-grid.md and docs/ruling-the-app-is-silent-and-the-panel-speaks.md
both recorded as ruled-but-not-scheduled ("the lamps compress to the side",
"we don't need to do yet"). Written down per CLAUDE.md rule 4 — the spec
below is not built, and a session that starts building it should start here.

## The ruling, in the user's words

> "Right now it's actually small enough that I can keep it alive all the time,
> and being able to easily hide it or show it is great too. I think it can
> collapse even more into just your lights. It can just be a light bar, and if
> you click on it, it just shows you if something's back. It doesn't even have
> to show you what it is. It can literally just be that color and our logo and
> that's it."
>
> "From top to bottom, the simplest thing would be just to collapse it to 40px
> wide, where you just show the lamps and, at the top, the logo."
>
> "It should be very contextual, and maybe your state is whatever you currently
> left it as, like collapsed versus expanded. It just stays in that state unless
> you change it, because you can totally use this by just looking at the lights."
>
> "On collapse, it could basically just be your lights. At the bottom, I think it
> could be the X when it's collapsed, and at the top it is Expand. Everything
> else stays the same, and it just shows your lamps. Maybe it doesn't even need
> to show the idle lamps when it's collapsed. It just shows those on expanded."
>
> "It's really just one question: green light or no, right? Am I ready? Am I
> waiting on it, or is it waiting on me? That's honestly the only question."
>
> "The control option when it's minimized should just bring up the grid, whether
> it's collapsed or not. It should basically be collapsed based on what your last
> state was."
>
> "Feel free to collapse it. Free up your screen real estate. The whole point is
> this is contextual, and you can need one click to expand it. It stays expanded
> until you're ready to collapse it again."

One sentence: **the grid has two widths, the user owns which one, and the app
never changes it for them.**

## What follows without interpretation

**A second width, not a second face.** The collapsed strip is `.idle` rendered
narrow — the same `SessionRow` data through the same `render()` arm, per 3a's
one-paint-funnel rule. It is not a new `PanelState` and not a new `show*` entry
point; it is a property of the idle face that `render()` reads. A session that
implements this by adding a state has misread it.

**The collapsed geometry.** ~40px wide, height unchanged. Logo at top, lamps
stacked below it, Expand at the top, dismiss (the X) at the bottom. Nothing
else: no callsigns, no topics, no `AGENTS` strip label, no `gridHint` key line.
The lamp's 9px circle and its four fills (`StateLegend.Lamp`) are already the
whole vocabulary the strip needs — collapsing changes what is omitted, never
what a color means.

**Idle lamps drop out when collapsed.** They return on expand. See open
question 1 for what counts as idle.

**Stickiness is the load-bearing part.** Collapsed-vs-expanded is durable user
state, persisted across relaunch (the app installs with a login item — it
restarts more often than the user thinks about it). Dismiss and re-summon
returns to the state you left, and so does `⌃⌥` when the panel is hidden: it
brings up the grid at whatever width it was last at. Nothing else sets it.

**Ordering is explicitly de-prioritized** — "the ordering doesn't matter that
much." WS-B's rule (green newest-first, then quiet) stands; this ruling does not
reopen it, and no session should spend a pass on it.

## Open — do not guess these

1. **What "idle lamps" means.** `Lamp` has four cases. `.ready` (green) and
   `.fault` (amber) obviously survive collapse. `.running` (quiet putty) is
   obviously the "idle lamp" being dropped. `.working` (advisory blue) is
   genuinely ambiguous: the ruling's own test is "am I waiting on it, or is it
   waiting on me", and blue is precisely the first half of that — which argues
   it survives. *This session's read, not ruled: hide `.running`, keep
   `.working`.* Needs Robert.

2. **Collapse vs. Minimize — one control or two.** The ruling says "it's
   possible you might want two controls." Note that a third tier already
   exists and ships: dismiss hides the panel outright and the menu-bar item
   carries the count (WS-B, `menuBarCount`). So the tiers are already
   expanded / hidden, and this ruling inserts collapsed between them. *This
   session's read, not ruled: no new Minimize control — the existing dismiss
   IS minimize, and a fourth tier buys nothing.* Needs Robert.

3. **When, if ever, anything collapses on its own.** The ruling is explicit
   that this is unresolved — "the conditions of when that happens I'm not
   completely sure." Until it is ruled, the answer is **nothing auto-collapses**,
   because that is the only behaviour that cannot be wrong. *This session's
   read, not ruled: it should stay that way permanently. A strip whose shape is
   constant and whose colour is the only variable is glanceable; one that
   reorganizes itself while you are not looking has to be re-read each time,
   which is the calm the product is selling being spent on cleverness.*

4. **Reflow when a lamp appears.** In a 40px column that hides idle lamps, a
   session going quiet→ready must appear, which moves every lamp below it. This
   is the one place motion is unavoidable in the resting face. Stable slots (a
   lamp keeps its position and fades between fills) versus a reflowing stack are
   materially different products; the first costs a fixed 8-slot column, the
   second costs the user their positional memory. Not ruled either way.

5. **Screen position.** "You could totally use the whole thing just in the
   single-column contextual view on the right" — unclear whether the collapsed
   strip docks to a screen edge or stays where the panel is. Today the panel is
   a positioned floating card; docking is a different amount of work. Not ruled.

## What this does not touch

Core, the announcement path, the away-channel law, and speech. The strip is a
width, not a voice — silence at rest is already ruled and this makes the resting
face quieter still, which is the same direction.

Panel work is one session at a time (CLAUDE.md rule 5), and the panel's evidence
is the launch self-tests, not `swift test` (rule 7). The collapsed strip is new
panel behaviour and therefore owes `--selftest-hud` a state: the matrix should
prove that collapsing omits widgets rather than merely hiding them behind a
narrower window, which is exactly the residue class 3a's `render()` was built to
make impossible.
