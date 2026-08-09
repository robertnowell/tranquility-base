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
stacked below it, dismiss (the X) at the bottom. Nothing else: no callsigns, no
topics, no `AGENTS` strip label, no `gridHint` key line. The lamp's 9px circle
and its four fills (`StateLegend.Lamp`) are already the whole vocabulary the
strip needs — collapsing changes what is omitted, never what a color means.

**All collapsed chrome is hover-revealed** (ruled 08 Aug, second and third
passes). At rest the strip is exactly what the first ruling described: "that
color and our logo and that's it." While the cursor is anywhere over the panel,
the logo swaps in place to the Expand affordance and the X appears at the
bottom; on exit both revert. Expand has no slot of its own — it *is* the logo's
slot.

**The X minimizes to the menu bar, from either width** — "when it's collapsed or
whatever, the X just minimizes it to the top bar." It is not a close and not a
collapse; it is the existing dismiss, reachable at both widths, and it lands in
the third tier below.

The swap is in place and the header keeps one fixed slot, so nothing below it
ever moves — **the collapsed strip has no vertical movement caused by chrome.**
This is the whole reason the control is a swap and not a row: a dedicated Expand
row would push the lamps down, and the lamps holding still is the property that
makes the strip readable at a glance. Any implementation where hovering reflows
the column has lost the point of the design.

**Idle lamps drop out when collapsed; blue stays.** `.running` (quiet putty) is
the idle lamp and is omitted while collapsed, returning on expand. `.ready`,
`.working`, and `.fault` all survive collapse — ruled 08 Aug, second pass: blue
is "I am waiting on it", which is half of the only question the strip answers.

**Stickiness is the load-bearing part.** Collapsed-vs-expanded is durable user
state, persisted across relaunch (the app installs with a login item — it
restarts more often than the user thinks about it). Dismiss and re-summon
returns to the state you left, and so does `⌃⌥` when the panel is hidden: it
brings up the grid at whatever width it was last at. Nothing else sets it.

**Ordering is explicitly de-prioritized** — "the ordering doesn't matter that
much." WS-B's rule (green newest-first, then quiet) stands; this ruling does not
reopen it, and no session should spend a pass on it.

**Three states, and only three** (ruled 08 Aug, third pass — "yes, only 3
states"). There is no Minimize control, because the third tier already ships:

| | footprint | shows | reached by |
|---|---|---|---|
| expanded | the grid | all lamps + callsigns, idle included | Expand (the logo, on hover) |
| collapsed | ~40px strip | ready / working / fault lamps | Collapse |
| minimized | menu-bar item only | the waiting count (`menuBarCount`) | the X, from either width |

**Nothing ever auto-collapses** (ruled 08 Aug, third pass, adopting this
session's recommendation). The width changes when the user changes it and at no
other time. A strip whose shape is constant and whose colour is the only
variable can be read at a glance; one that reorganizes itself while you are not
looking has to be re-read every time, which spends the exact calm the product
is selling.

## Open — do not guess these

Questions 1, 1b, 2 and 3 were all resolved on 08 Aug within the same evening and
have moved into the ruled section above: blue survives collapse, the X is
hover-revealed, there are three states and no Minimize control, and nothing
auto-collapses.

4. **Reflow when a lamp appears.** In a 40px column that omits idle lamps, a
   session going quiet→ready makes a lamp *appear*, moving every lamp below it.
   This is the last place vertical movement can enter the resting face, and the
   ruled principle — chrome must never push the lamps down — argues it should
   not be allowed in through the back door either.

   Posed originally as fixed-8-slot-column versus reflowing-stack. There is a
   third reading that may dissolve it, and a session picking this up should
   consider it first: **`.running` already renders as a socket, not a lamp** —
   `StateLegend.Lamp.running` is hover putty with a hairline ring, described in
   its own doc comment as reading "as a socket, not an absence." So "hide the
   idle lamps" and "never move the live ones" may not be in conflict at all:
   keep one slot per live session, and let idle sessions render as the socket
   they already are. Nothing moves when a session lights up, because the slot
   was always there, and the strip at rest is still just colour and logo because
   an unlit socket is nearly invisible against the surface.

   That reading is this session's, not Robert's, and it changes what "idle lamps
   drop out" means — under it they dim rather than disappear. Worth one sentence
   of confirmation before anyone builds it. Needs Robert.

5. **Screen position.** "You could totally use the whole thing just in the
   single-column contextual view on the right" — unclear whether the collapsed
   strip docks to a screen edge or stays where the panel already floats. Today
   the panel is a positioned floating card; docking is a different amount of
   work. Still not ruled.

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
