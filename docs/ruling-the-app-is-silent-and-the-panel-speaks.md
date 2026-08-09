# The app is silent, and the panel is how it speaks

Ruled 08 Aug 2026, spoken. Written down because a ruling that lives only in a
conversation cannot be honoured by the sessions that did not have it — CLAUDE.md
rule 4. Part of this is already law in the code; part of it is not built yet.
Both are recorded here so the built part is not undone and the unbuilt part is
not re-argued.

## The ruling, in the user's words

> "I think it should always announce silently. It announces visually: it shows
> you the grid, and then you hit Control Option to start interacting."
>
> "For the new user experience, like the first onboarding experience, for sure we
> should never [speak]."
>
> "Potentially, if the app has been active for a while without being
> initialised, like 'Type Control Option to get started' — that's fine, maybe
> after 10 seconds."
>
> "Generally speaking, it should be silent at one point, and even on startup, at
> most it should show the lamps compressed on the side, which we don't need to do
> yet."

One sentence: **the app does not talk about itself.** Speech is for content the
user asked for and is not looking at. Everything the app has to say about its own
state is a thing on screen.

This is the away-channel law applied to the app's own voice: *if it can be
communicated visually, it is not spoken.* The panel already obeys this for agent
content. The ruling extends it to the app's own existence.

## Already true — do not undo

**No spoken greeting at launch.** `main.swift:490`, in the code's own words:

> "Launch is a state the user caused, watching the screen — the away-channel law
> at its purest… Apps also relaunch mid-work (rebuilds, updates), and announcing
> yourself each time is noise from the exact product that promised calm. The idle
> card appearing IS the greeting."

This is load-bearing beyond taste as of 08 Aug: the app now installs to
`/Applications` with a login item (`scripts/install.sh`), so it starts at every
login. An app that talks at you at every boot is an app whose login item gets
switched off. Silence at launch is what makes starting at login acceptable.

## Not yet true — the unbuilt half

1. **Never speak during first-run onboarding.** `Onboarding` is shown when
   permissions are missing (`main.swift:496`). It must stay mute: a user who has
   not yet granted the microphone is the least appropriate audience for a voice,
   and the first thing the app ever does sets the expectation for everything after.

2. **A visual hint after ~10 seconds of an uninitialised session** — "⌃⌥ to get
   started", on screen, never spoken. Not a nag and not a tour: one line, once,
   for the case where the app is running and the user has not yet discovered the
   gesture. Confirmed absent from the source at `3f65da5`.

3. **Silence as the resting posture, not the exception.** Any new surface that
   wants a voice argues for it against this ruling rather than inheriting it.

## Direction — SUPERSEDED the same evening

> **Both items below were scheduled hours after this was written.** See
> **docs/ruling-the-collapsed-strip.md**, which carries the geometry, the
> stickiness requirement, and four open questions. CLAUDE.md rule 4: the later
> ruling wins, and this section is kept only so a session that arrives here first
> is sent there rather than concluding the work is unscheduled.

Recorded originally as not-scheduled:

- **The grid becomes contextual.** Today `showIdle(note:rows:)` draws one row per
  live session, capped at 8 (docs/ws-b-grid.md). The intent is that what the idle
  face shows becomes state-determined rather than a fixed list.
- **The lamps compress to the side.** A denser resting face where the session
  lamps sit at the edge rather than occupying the card. Explicitly "we don't need
  to do yet".

## Why this doc exists at all

08 Aug ran three separate incidents in one evening, one of which was another
session deploying mid-conversation and taking the menu bar down. Parallel
sessions cannot arbitrate a ruling they cannot read, and CLAUDE.md rule 4 says
the later ruling wins — which only works if the later ruling is somewhere a
session will look. The cost of writing this down is ten minutes; the cost of not
doing so is a session cheerfully adding a launch chime because nothing told it
not to.
